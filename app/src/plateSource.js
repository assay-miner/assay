/**
 * The text the plate's code rain is cut from, and that the retype animation pulls its
 * replacement glyphs out of. It is the actual assay path — the Yul that meters a submission —
 * rather than decorative filler, so the texture is the protocol looked at very closely.
 * Whitespace is stripped so it packs like a memory dump.
 *
 * Plain JS on purpose: both the browser bundle and `tools/gen-hero.mjs` import this exact file,
 * so the glyphs the generator engraves and the glyphs the animation types back can never drift
 * apart into two slightly different strings.
 */
export const SOURCE = (
  "function assay(address impl,Vector[] memory v,uint256 cap)internal view returns(bool ok,uint256 gasUsed){" +
  "uint256 g0=gas();success:=staticcall(cap,impl,add(input,0x20),mload(input),0,0);gasUsed:=sub(g0,gas())" +
  "returndatacopy(scratch,0,returndatasize());outHash:=keccak256(scratch,returndatasize())" +
  "if(!success||outHash!=v[i].expected)return(false,0);total+=g;" +
  "initcode=abi.encodePacked(hex'63',uint32(n),hex'80600E6000396000F3',runtime);impl:=create(0,add(initcode,0x20),mload(initcode))" +
  "score=min(baselineGas*1e18/gasUsed,32e18);if(gasUsed>=baselineGas)score=0;" +
  "commitment==keccak256(abi.encode(runtime,salt,agentId))" +
  "PUSH1 0x00 CALLDATALOAD DUP1 MUL PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN" +
  "require(identityRegistry.isAuthorizedOrOwner(msg.sender,agentId));stake>=minStake;" +
  "payout=pot*submission.score/task.totalScore;"
).replace(/\s+/g, "");
