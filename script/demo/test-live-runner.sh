#!/usr/bin/env bash
# Offline tests for live-aqueous-early-release.sh. Nothing here touches a network or a real key.
#
# `forge` and `cast` are replaced by stubs on PATH, so each failure path the curator asked about can
# be forced and then checked against the journal:
#
#   A. forge broadcasts, then the receipt read fails     -> hash journaled, exit 1, forge called once
#   B. forge exits nonzero after printing a tx hash      -> hash journaled, exit 1, forge called once
#   C. getPolicy cannot be read                          -> refused before any step runs
#   D. getPolicy returns an inactive policy              -> refused
#   E. step 4 then 5 in one run                          -> step 5 sees DEMO_COMMITMENT_ID from the event
#   F. step 5 alone                                       -> DEMO_COMMITMENT_ID loaded from the journal
#
# Usage: script/demo/test-live-runner.sh
set -uo pipefail

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/live-aqueous-early-release.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

HASH_A=0x1111111111111111111111111111111111111111111111111111111111111111
COMMIT_HASH=0x2222222222222222222222222222222222222222222222222222222222222222
COMMIT_ID=0x3333333333333333333333333333333333333333333333333333333333333333
RECOMPUTER=0x4d1a62869d16ab2bac95408445129c4927f88457
CODEHASH=0x5555555555555555555555555555555555555555555555555555555555555555
CORE=0x9d673a8b5efe76d42593b45972fa0426648967e1

mkdir -p "$T/bin" "$T/ws" "$T/repo/script/demo"
cp "$RUNNER" "$T/repo/script/demo/"
printf 'HOUSE_WALLET_PRIVATE_KEY=0xaa\nDEMO_BUYER_KEY=0xbb\n' > "$T/ws/.env"

# cast stub: behaviour switched by env vars set per case.
cat > "$T/bin/cast" <<EOF
#!/usr/bin/env bash
echo "cast \$*" >> "$T/calls"
case "\$1" in
  chain-id) echo 143 ;;
  rpc) exit 1 ;;                                   # anvil_nodeInfo unsupported, so not a fork
  block-number) echo 1 ;;
  keccak) [[ "\$2" == 0xc0de ]] && echo $CODEHASH || echo 0x0f ;;
  code) echo 0xc0de ;;
  wallet) echo 0x00000000000000000000000000000000000000a1 ;;
  balance) echo 1 ;;
  call)
    if [[ "\$3" == getPolicy* ]]; then
      [[ "\${POLICY_MODE:-ok}" == fail ]] && exit 1
      act=true; [[ "\${POLICY_MODE:-ok}" == inactive ]] && act=false
      echo "[[\"$RECOMPUTER\",\"$CODEHASH\",\"100000000000000000\",1500000,200000,32,\$act]]"
    else echo 0x00; fi ;;
  receipt)
    [[ "\${RECEIPT_MODE:-ok}" == fail ]] && { echo "error: timeout" >&2; exit 1; }
    if [[ "\$*" == *--json* ]]; then
      echo '{"logs":[{"address":"$CORE","topics":["0xev","$COMMIT_ID"]}]}'
    else echo 1; fi ;;
  *) echo "unexpected cast \$*" >&2; exit 2 ;;
esac
EOF

# forge stub: records the contract and the env it saw, writes a run file like forge does.
cat > "$T/bin/forge" <<EOF
#!/usr/bin/env bash
c=\$(printf '%s\n' "\$@" | grep -o ':[A-Za-z]*\$' | tr -d :)
echo "forge \$c DEMO_COMMITMENT_ID=\${DEMO_COMMITMENT_ID:-unset}" >> "$T/calls"
f=broadcast/AqueousEarlyReleaseDemo.s.sol/143/run-latest.json; mkdir -p "\$(dirname "\$f")"
h=$HASH_A; [[ "\$c" == DemoAgentCommit ]] && h=$COMMIT_HASH
if [[ "\${FORGE_MODE:-ok}" == die ]]; then
  echo "Transaction hash: \$h"; echo "Error: server returned an error response"; exit 1
fi
echo "{\"transactions\":[{\"hash\":\"\$h\"}],\"receipts\":[{\"transactionHash\":\"\$h\"}]}" > "\$f"
echo "##### 143 ✅ [Success] Hash: \$h"
EOF
chmod +x "$T/bin/cast" "$T/bin/forge"

pass=0; fail=0
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
run() { # steps..., env set by caller
  rm -f "$T/calls" "$T/out"
  (cd "$T/repo" && PATH="$T/bin:$PATH" WORKSPACE="$T/ws" MONAD_RPC_URL=stub JOURNAL="$T/journal" \
     LIVE=1 WINDOW_CONFIRMED=1 bash script/demo/live-aqueous-early-release.sh "$@" > "$T/out" 2>&1)
  echo $? > "$T/code"
}
forges() { awk '/^forge/{n++} END{print n+0}' "$T/calls" 2>/dev/null || echo 0; }

echo "A. broadcast, then receipt read fails"
rm -f "$T/journal"; RECEIPT_MODE=fail run 2
check "exits nonzero"                    '[[ $(cat "$T/code") != 0 ]]'
check "hash is in the journal"           'grep -q "$HASH_A" "$T/journal"'
check "receipt failure is journaled"     'grep -q "receipt read failed" "$T/journal"'
check "forge ran once, nothing resent"   '[[ $(forges) == 1 ]]'
check "says nothing was resent"          'grep -q "Nothing was resent" "$T/out"'

echo "B. forge dies after printing a hash, no run file"
rm -f "$T/journal" "$T/repo/broadcast" -r; FORGE_MODE=die run 3
check "exits nonzero"                    '[[ $(cat "$T/code") != 0 ]]'
check "printed hash is journaled"        'grep -q "$HASH_A" "$T/journal"'
check "journal row names forge exit 1"   'grep -q "forge exit 1" "$T/journal"'
check "forge ran once"                   '[[ $(forges) == 1 ]]'

echo "C. getPolicy unreadable"
rm -f "$T/journal"; POLICY_MODE=fail run 2
check "refused"                          'grep -q "REFUSED: could not read getPolicy" "$T/out"'
check "no step ran"                      '[[ $(forges) == 0 ]]'

echo "D. getPolicy inactive"
POLICY_MODE=inactive run 2
check "refused"                          'grep -q "REFUSED: policy .* is not active" "$T/out"'
check "no step ran"                      '[[ $(forges) == 0 ]]'

echo "E. steps 4 and 5 in one run"
rm -f "$T/journal"; run 4 5
check "exits zero"                       '[[ $(cat "$T/code") == 0 ]]'
check "commitment id journaled"          'grep -q "commitment id	$COMMIT_ID" "$T/journal"'
check "release saw the exported id"      'grep -q "forge DemoBuyerReleaseEarly DEMO_COMMITMENT_ID=$COMMIT_ID" "$T/calls"'
check "via the export, not the journal"  '! grep -q "loaded from the journal" "$T/out"'

echo "F. step 5 alone, id from the journal"
run 5
check "exits zero"                       '[[ $(cat "$T/code") == 0 ]]'
check "loaded from the journal"          'grep -q "loaded from the journal: $COMMIT_ID" "$T/out"'
check "release saw that id"              'grep -q "forge DemoBuyerReleaseEarly DEMO_COMMITMENT_ID=$COMMIT_ID" "$T/calls"'

echo "G. step 5 alone, no id anywhere"
rm -f "$T/journal"; run 5
check "refused"                          'grep -q "REFUSED: step 5 needs DEMO_COMMITMENT_ID" "$T/out"'
check "no release sent"                  '[[ $(forges) == 0 ]]'

echo; echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
