#!/usr/bin/env bash
# The LIVE mainnet half of the coordinated Aqueous early-release demonstration.
#
# This is not the rehearsal. script/demo/rehearse-aqueous-early-release.sh is fork-only by
# construction: it calls anvil_setBalance, impersonates every signer with --unlocked and advances the
# chain with anvil_mine. None of those exist on mainnet. This script runs only the four steps that
# are ours, with real keys, against chain 143.
#
#   ours   : 0 top up the buyer's gas, 2 approve, 3 open the flat job, 4 commit the bounty, 5 release early
#   theirs : 6 seal, 7 reveal, 8 withdraw, from the curator's own challenger key
#
# Three things this refuses to do, each for a reason that cost something to learn.
#
#  1. **It does not register the policy.** The reviewed policy is already registered on mainnet, so
#     calling registerPolicy again reverts `policy already registered`. The rehearsal's step 1 is
#     therefore skipped and the live sequence starts at step 2. The script asserts the policy is
#     there instead, because committing a bounty against a policy that was revoked would burn it.
#  2. **It does not broadcast unless told twice.** Dry run is the default. LIVE=1 broadcasts. Step 4
#     additionally needs WINDOW_CONFIRMED=1, because the commitment window is two hours and cannot be
#     paused: committing before the challenger is at the keyboard risks the bounty for nothing. That
#     rule lives here rather than in a note, so a later run cannot forget it.
#  3. **It will not run against a fork.** A script that silently passes on anvil teaches you nothing
#     about mainnet. The RPC has to be chain 143 and must not answer anvil_nodeInfo.
#
# Every hash is appended to the journal the instant forge reports it, before any receipt is read. A
# broadcast that succeeded and whose receipt read failed is still money that moved, so the identifier
# has to be on disk before anything can throw.
#
# Keys are sourced at the point of use from the workspace env and never written anywhere.
#
# Usage:
#   MONAD_RPC_URL=https://rpc.monad.xyz script/demo/live-aqueous-early-release.sh            # dry run
#   MONAD_RPC_URL=... LIVE=1 script/demo/live-aqueous-early-release.sh 2 3                   # broadcast 2 and 3
#   MONAD_RPC_URL=... LIVE=1 WINDOW_CONFIRMED=1 script/demo/live-aqueous-early-release.sh 4 5
#
# Needs Foundry 1.8.1 on PATH and jq.
set -euo pipefail

WORKSPACE="${WORKSPACE:-$HOME/Downloads/hackathon-hq}"
RPC="${MONAD_RPC_URL:?set MONAD_RPC_URL to a Monad mainnet RPC}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE"

JOURNAL="${JOURNAL:-$HERE/.live-demo-journal.tsv}"
RUN_FILE="broadcast/AqueousEarlyReleaseDemo.s.sol/143/run-latest.json"

POLICY_REGISTRY=0x2a26e33cd2118a2d340bba810e23a8e5cfde8e38
DISSENT_CORE=0x9D673a8B5EfE76D42593b45972Fa0426648967E1
AQUEOUS=0xd75f7786D0DD42c8F161Bd78E87D37001044Fc32
POLICY_ID=0x52655800591f954bb48cfd67e41475ec394898cd8e2e1cd8a7fa3350f7c479f8
RECOMPUTER=0x4d1A62869D16AB2Bac95408445129C4927f88457

# The curator's live challenger, from their own comment on PR #7. Never the rehearsal placeholder.
export DEMO_CHALLENGER="${DEMO_CHALLENGER:-0x00cf6ceC697E3DCB88a5972Ef083B423dfC00A02}"
export DEMO_JOB_SALT="${DEMO_JOB_SALT:-$(cast keccak 'kanmani.dissent.demo.aqueous-early-release.v1')}"
export DEMO_REWARD_WEI="${DEMO_REWARD_WEI:-750000000000000000}"   # 0.75 MON, agreed in the thread
BUYER_GAS_TOPUP="${BUYER_GAS_TOPUP:-0.1ether}"

LIVE="${LIVE:-0}"
STEPS=("$@")
[[ ${#STEPS[@]} -gt 0 ]] || STEPS=(0 2 3 4 5)

note() { printf '%s\n' "$*"; }
die()  { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- guards

note "== guards"
CHAIN=$(cast chain-id --rpc-url "$RPC")
[[ "$CHAIN" == 143 ]] || die "chain id is $CHAIN, not 143"
if cast rpc anvil_nodeInfo --rpc-url "$RPC" >/dev/null 2>&1; then
  die "this RPC answers anvil_nodeInfo, so it is a fork. Use the rehearsal script for forks."
fi
note "  chain 143, not a fork, head $(cast block-number --rpc-url "$RPC")"

[[ "$DEMO_CHALLENGER" != "0xb9466199d0cb372e23df140836d33fd6d9dbd032" ]] \
  || die "DEMO_CHALLENGER is the rehearsal placeholder, which nobody holds a key for"
[[ -z "${DEMO_REHEARSAL:-}" ]] || die "DEMO_REHEARSAL is set, which is a fork-only override"

# The policy has to still be live. Committing against a revoked policy spends the bounty for nothing.
POLICY_CODE_OWNER=$(cast call "$POLICY_REGISTRY" 'policyRecomputer(bytes32)(address)' "$POLICY_ID" --rpc-url "$RPC" 2>/dev/null || echo "")
if [[ -n "$POLICY_CODE_OWNER" ]]; then
  [[ "${POLICY_CODE_OWNER,,}" == "${RECOMPUTER,,}" ]] \
    || die "policy $POLICY_ID maps to $POLICY_CODE_OWNER, not the reviewed recomputer $RECOMPUTER"
  note "  policy registered against the reviewed recomputer"
else
  # The getter name is not part of what we reviewed, so a failed read is reported rather than
  # treated as absence. Absence of evidence is not evidence of absence.
  note "  NOTE: could not read the policy through policyRecomputer(bytes32). Confirm by hand before step 4."
fi

set -a; . "$WORKSPACE/.env"; set +a
AGENT=$(cast wallet address --private-key "$HOUSE_WALLET_PRIVATE_KEY")
BUYER=$(cast wallet address --private-key "$DEMO_BUYER_KEY")
export DEMO_AGENT="$AGENT" DEMO_BUYER="$BUYER"
export DEMO_AGENT_SALT="${DEMO_AGENT_SALT:-$(cast keccak 'kanmani.dissent.demo.agent.v1')}"

note "  agent  $AGENT  $(cast balance "$AGENT" --rpc-url "$RPC" --ether) MON"
note "  buyer  $BUYER  $(cast balance "$BUYER" --rpc-url "$RPC" --ether) MON"
note "  challenger $DEMO_CHALLENGER  $(cast balance "$DEMO_CHALLENGER" --rpc-url "$RPC" --ether) MON"
note "  bounty $DEMO_REWARD_WEI wei"
note "  job salt $DEMO_JOB_SALT"
[[ "$LIVE" == 1 ]] && note "  LIVE=1, transactions WILL broadcast" || note "  dry run, nothing broadcasts (set LIVE=1 to send)"

record() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$JOURNAL"; }

forge_step() { # name, contract, private-key-var
  local name="$1" contract="$2" keyvar="$3"
  note ""
  note "== $name"
  if [[ "$LIVE" != 1 ]]; then
    forge script "script/AqueousEarlyReleaseDemo.s.sol:$contract" --rpc-url "$RPC" \
      --private-key "${!keyvar}" 2>&1 | grep -vi 'private key\|secret' | tail -12
    note "  simulated only"
    return
  fi
  rm -f "$RUN_FILE"
  local out code
  set +e
  out=$(forge script "script/AqueousEarlyReleaseDemo.s.sol:$contract" --rpc-url "$RPC" \
    --private-key "${!keyvar}" --broadcast 2>&1)
  code=$?
  set -e
  printf '%s\n' "$out" | grep -vi 'private key\|secret' | tail -14
  [[ $code -eq 0 ]] || { note "step failed: forge exited $code"; exit 1; }
  [[ -s "$RUN_FILE" ]] || { note "step failed: forge wrote no run file"; exit 1; }
  [[ "$(jq '.receipts | length' "$RUN_FILE")" == 1 ]] || { note "step failed: expected exactly one transaction"; exit 1; }
  LAST_HASH=$(jq -r '.receipts[0].transactionHash' "$RUN_FILE")
  record "$name" "$LAST_HASH"                       # on disk BEFORE any receipt read
  local st; st=$(cast receipt "$LAST_HASH" status --rpc-url "$RPC")
  [[ "$st" == true || "$st" == 1* ]] || { note "step failed: $LAST_HASH reverted"; exit 1; }
  note "  $LAST_HASH ok"
}

has() { local n="$1"; for s in "${STEPS[@]}"; do [[ "$s" == "$n" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- steps

if has 0; then
  note ""
  note "== 0 agent sends the buyer $BUYER_GAS_TOPUP for gas"
  if [[ "$LIVE" != 1 ]]; then
    note "  dry run, would send $BUYER_GAS_TOPUP from $AGENT to $BUYER"
  else
    h=$(cast send "$BUYER" --value "$BUYER_GAS_TOPUP" --private-key "$HOUSE_WALLET_PRIVATE_KEY" \
        --rpc-url "$RPC" --json | jq -r .transactionHash)
    record "0 agent tops up buyer gas" "$h"
    [[ "$(cast receipt "$h" status --rpc-url "$RPC")" == true ]] || { note "top-up failed"; exit 1; }
    note "  $h ok, buyer now $(cast balance "$BUYER" --rpc-url "$RPC" --ether) MON"
  fi
fi

has 2 && forge_step "2 buyer approves 0.10 USDC" DemoBuyerApprove DEMO_BUYER_KEY
has 3 && forge_step "3 buyer opens flat job" DemoBuyerOpenJob DEMO_BUYER_KEY

if has 4; then
  [[ "${WINDOW_CONFIRMED:-0}" == 1 ]] || die "step 4 opens a two hour window that cannot be paused. Set WINDOW_CONFIRMED=1 only once the challenger has confirmed they are ready."
  forge_step "4 agent commits bounty" DemoAgentCommit HOUSE_WALLET_PRIVATE_KEY
  if [[ "$LIVE" == 1 ]]; then
    COMMITMENT_ID=$(cast receipt "$LAST_HASH" --rpc-url "$RPC" --json \
      | jq -r --arg core "$(echo "$DISSENT_CORE" | tr 'A-F' 'a-f')" \
        '[.logs[] | select((.address|ascii_downcase)==$core)][-1].topics[1]')
    [[ "$COMMITMENT_ID" =~ ^0x[0-9a-f]{64}$ ]] || { note "no Committed event in the commit receipt"; exit 1; }
    record "commitment id" "$COMMITMENT_ID"
    note "  commitment id from the Committed event: $COMMITMENT_ID"
  fi
fi

has 5 && forge_step "5 buyer releases early" DemoBuyerReleaseEarly DEMO_BUYER_KEY

# ---------------------------------------------------------------- state

note ""
note "== state to post in the thread"
JOB=$(cast call "$AQUEOUS" 'jobIdFor(address,address,bytes32)(bytes32)' "$BUYER" "$AGENT" "$DEMO_JOB_SALT" --rpc-url "$RPC")
note "  job id        $JOB"
note "  policy id     $POLICY_ID"
note "  recomputer    $RECOMPUTER"
note "  challenger    $DEMO_CHALLENGER"
note "  journal       $JOURNAL"
if [[ "$LIVE" == 1 ]]; then
  note "  job state (3 = Settled): $(cast call "$AQUEOUS" 'jobs(bytes32)((address,uint64,uint8,address,uint64,address,uint128,uint128,bytes32,bytes32))' "$JOB" --rpc-url "$RPC" | tr -d '()' | cut -d, -f3 | tr -d ' ')"
fi
note ""
note "Theirs next: 6 seal, wait 5 blocks, 7 reveal, 8 withdraw."
