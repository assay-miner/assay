// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {AssayVault} from "./AssayVault.sol";

/// @title AgentRoster
/// @notice Binds a mining address to an ERC-8004 agent identity and holds its stake.
/// @dev Sybil resistance is two-layered on purpose. The ERC-8004 identity makes each miner a
///      first-class, externally-visible agent (it shows up in BNB Chain's own agent explorers),
///      and the stake makes minting a fresh identity per submission cost real capital.
///
///      A miner's operating key never has to hold the identity NFT: enrolment is checked with
///      `isAuthorizedOrOwner`, so the NFT can stay in cold storage while a disposable hot key
///      does the mining.
///
///      This contract never holds a token. Stake lives in `AssayVault`, in an account namespaced
///      to this contract, so the tournament cannot reach it and neither can anybody's admin key.
contract AgentRoster {
    /// @notice Account namespace for miner stake inside the vault.
    bytes32 public constant KIND_STAKE = "stake";

    IIdentityRegistry public immutable identityRegistry;
    AssayVault public immutable vault;
    uint256 public immutable minStake;

    /// @notice The tournament permitted to extend stake locks. Set once, then frozen forever.
    address public consumer;
    bool public consumerFrozen;

    /// @notice The address that constructed this roster, and the only one that may name the
    ///         tournament — once.
    /// @dev This used to be `curator`, which put a live permission behind the same hot key a
    ///      reviewer flagged on Tournament. The permission is one-shot and is spent during the
    ///      deploy, so it belongs to whoever is doing the deploying, not to whoever will be
    ///      running the protocol afterwards. After `setConsumer` the deployer has nothing left to
    ///      call; the one privileged caller that remains is the consumer itself, which is the
    ///      tournament, and it holds only `lockUntil`.
    address public immutable deployer;

    struct Enrolment {
        uint256 agentId;
        uint256 stake;
        uint64 lockedUntil;
    }

    mapping(address miner => Enrolment) private _enrolments;
    /// @notice Reverse index, so one identity cannot back two mining addresses at once.
    mapping(uint256 agentId => address miner) public minerOf;

    event Enrolled(address indexed miner, uint256 indexed agentId, uint256 stake);
    event StakeIncreased(address indexed miner, uint256 amount, uint256 total);
    event StakeLocked(address indexed miner, uint64 lockedUntil);
    /// @notice A binding was taken from a holder the registry no longer authorises for that id.
    event BindingReleased(uint256 indexed agentId, address indexed from, address indexed to);

    event Withdrawn(address indexed miner, uint256 indexed agentId, uint256 amount);
    event ConsumerSet(address indexed consumer);


    constructor(IIdentityRegistry registry, AssayVault vault_, uint256 minStake_) {
        identityRegistry = registry;
        vault = vault_;
        minStake = minStake_;
        deployer = msg.sender;
    }

    /// @notice The vault account holding `miner`'s stake. Anyone can read its balance directly.
    function stakeAccount(address miner) public view returns (bytes32) {
        return vault.accountId(address(this), KIND_STAKE, bytes32(uint256(uint160(miner))));
    }

    /// @notice Names the tournament allowed to lock stake, once.
    function setConsumer(address consumer_) external {
        require(msg.sender == deployer, unicode"Not the deployer / 非部署者");
        require(!consumerFrozen, unicode"Consumer is frozen / 消费者已冻结");
        consumer = consumer_;
        consumerFrozen = true;
        emit ConsumerSet(consumer_);
    }

    /// @notice Binds `msg.sender` to `agentId` and takes the stake.
    function enroll(uint256 agentId, uint256 stake) external {
        require(agentId != 0, unicode"Agent id is zero / agent 编号为零");
        // Bounded here because `Tournament.Submission.agentId` is a `uint64` and `commit` narrows to
        // it. A larger id would be truncated silently, and `reveal` recomputes the commitment from
        // the TRUNCATED value while the documented formula uses the full one — so the miner could
        // never reveal, could not score, and their stake stayed locked to `revealEnd` for nothing.
        // The `Revealed` event and the leaderboard card read the same narrowed field, so they would
        // have labelled them with the wrong agent besides.
        //
        // Refusing at enrolment costs the caller nothing; failing at reveal costs them a locked
        // stake and a wasted epoch. The ERC-8004 registry this points at mints sequential ERC-721
        // ids — `ownerOf(1)`, `ownerOf(2)` and `ownerOf(100)` all resolve on chain today — so
        // reaching this bound needs about 1.8e19 identities and no real caller will meet it. It is
        // here to make the truncation impossible rather than improbable, since the registry is a
        // contract we do not control.
        require(agentId <= type(uint64).max, unicode"Agent id too large / agent 编号过大");
        require(_enrolments[msg.sender].agentId == 0, unicode"Already enrolled / 已注册");

        // A binding survives only while its holder still holds the identity.
        //
        // `minerOf` used to be cleared in exactly one place — `withdraw`, by the bound miner — so an
        // identity sold to somebody else stayed bound to the seller for as long as the seller
        // declined to withdraw. The buyer passed `isAuthorizedOrOwner` and was refused anyway, and
        // there was nothing they could do about it: the only key that could release the binding was
        // the one that had just sold them the identity.
        //
        // So the binding is re-checked against the registry rather than trusted. A holder who still
        // has the identity keeps it, which is what stops this from being a way to take a live
        // binding; a holder who no longer does loses it to whoever the registry now authorises.
        // The seller's own enrolment is left alone — their stake is in it, and it stays theirs to
        // withdraw.
        address bound = minerOf[agentId];
        if (bound != address(0)) {
            // Wrapped, and the catch keeps the binding rather than releasing it. The registry is a
            // contract we do not control and an OZ ERC-721 reverts on a burned id, so an
            // unanswerable query would otherwise surface as its error instead of "Agent already
            // bound" — and, far worse, a registry that reverts on demand would be a way to release
            // every binding. A query we cannot make is not an answer that the holder lost the
            // identity.
            bool stillTheirs = true;
            try identityRegistry.isAuthorizedOrOwner(bound, agentId) returns (bool ok) {
                stillTheirs = ok;
            } catch {
                // Unanswerable, so nothing is released.
            }
            if (!stillTheirs) {
                emit BindingReleased(agentId, bound, msg.sender);
                bound = address(0);
            }
        }
        require(bound == address(0), unicode"Agent already bound / agent 已被绑定");
        require(
            identityRegistry.isAuthorizedOrOwner(msg.sender, agentId),
            unicode"Not authorised for this agent / 无该 agent 的权限"
        );
        require(stake >= minStake, unicode"Stake below minimum / 质押低于下限");

        _enrolments[msg.sender] = Enrolment({agentId: agentId, stake: stake, lockedUntil: 0});
        minerOf[agentId] = msg.sender;

        vault.deposit(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, stake);
        emit Enrolled(msg.sender, agentId, stake);
    }

    /// @notice Tops up an existing stake.
    function addStake(uint256 amount) external {
        Enrolment storage e = _enrolments[msg.sender];
        require(e.agentId != 0, unicode"Not enrolled / 未注册");
        e.stake += amount;
        vault.deposit(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, amount);
        emit StakeIncreased(msg.sender, amount, e.stake);
    }

    /// @notice Called by the tournament when a miner commits, so stake stays at risk for the
    ///         duration of the round it is backing.
    function lockUntil(address miner, uint64 until) external {
        require(msg.sender == consumer, unicode"Not the consumer / 非消费者");
        Enrolment storage e = _enrolments[miner];
        require(e.agentId != 0, unicode"Not enrolled / 未注册");
        if (until > e.lockedUntil) {
            e.lockedUntil = until;
            emit StakeLocked(miner, until);
        }
    }

    /// @notice Returns the whole stake and unbinds the identity.
    /// @dev Unbinding never invalidates an already-recorded submission: the tournament stores the
    ///      agentId on the submission itself, so a withdrawal cannot strand a pending claim.
    function withdraw() external {
        Enrolment memory e = _enrolments[msg.sender];
        require(e.agentId != 0, unicode"Not enrolled / 未注册");
        require(block.timestamp >= e.lockedUntil, unicode"Stake is locked / 质押锁定中");

        delete _enrolments[msg.sender];
        // Only if it is still ours. Once an identity has moved on and somebody else has bound it,
        // this withdrawal must not take THEIR binding with it — which is precisely what an
        // unconditional delete here would do, and it would look like the new owner had never
        // enrolled.
        if (minerOf[e.agentId] == msg.sender) delete minerOf[e.agentId];

        vault.payOut(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, e.stake);
        emit Withdrawn(msg.sender, e.agentId, e.stake);
    }

    /// @notice Reverts unless `miner` is enrolled; returns the bound agent id.
    function requireEnrolled(address miner) external view returns (uint256 agentId) {
        agentId = _enrolments[miner].agentId;
        require(agentId != 0, unicode"Not enrolled / 未注册");
        // The binding, not just the enrolment. Releasing a stale binding in `enroll` deliberately
        // leaves the old holder's enrolment alone — their stake is in it — and this is the line that
        // stops that from becoming a second way to mine the same identity.
        //
        // Without it one id backed any number of live enrolments, and the damage was not dilution.
        // `Tournament.commit` places no uniqueness constraint on `commitment` across miners and
        // `submissions` is a public mapping, so the released holder could copy the current holder's
        // commitment verbatim, wait for them to reveal, and replay the same (runtime, salt). It
        // verifies, because `reveal` hashes against `s.agentId` and both carried the same one.
        // Measured on the fixture: one leg took 44.6% of the pot for no work, three took 70.8%.
        //
        // `Tournament`'s own NatSpec is what this restores — "a stolen (runtime, salt) pair hashes
        // to a different commitment under a different agent id" was true only while an id had one
        // enrolled miner.
        //
        // It does not touch the stake: `withdraw` does not come through here, so a released holder
        // keeps everything they put in and can take it out. They simply cannot commit again.
        require(minerOf[agentId] == miner, unicode"Binding was released / 绑定已被释放");
    }

    function enrolmentOf(address miner) external view returns (Enrolment memory) {
        return _enrolments[miner];
    }
}
