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

    address public immutable curator;

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
    event Withdrawn(address indexed miner, uint256 indexed agentId, uint256 amount);
    event ConsumerSet(address indexed consumer);

    error NotCurator();
    error ConsumerAlreadyFrozen();
    error NotConsumer();
    error ZeroAgentId();
    error NotAuthorizedForAgent(address miner, uint256 agentId);
    error AgentAlreadyBound(uint256 agentId, address boundTo);
    error AlreadyEnrolled(address miner);
    error NotEnrolled(address miner);
    error StakeBelowMinimum(uint256 provided, uint256 required);
    error StakeLockedUntil(uint64 lockedUntil);

    constructor(IIdentityRegistry registry, AssayVault vault_, uint256 minStake_, address curator_) {
        identityRegistry = registry;
        vault = vault_;
        minStake = minStake_;
        curator = curator_;
    }

    /// @notice The vault account holding `miner`'s stake. Anyone can read its balance directly.
    function stakeAccount(address miner) public view returns (bytes32) {
        return vault.accountId(address(this), KIND_STAKE, bytes32(uint256(uint160(miner))));
    }

    /// @notice Names the tournament allowed to lock stake, once.
    function setConsumer(address consumer_) external {
        if (msg.sender != curator) revert NotCurator();
        if (consumerFrozen) revert ConsumerAlreadyFrozen();
        consumer = consumer_;
        consumerFrozen = true;
        emit ConsumerSet(consumer_);
    }

    /// @notice Binds `msg.sender` to `agentId` and takes the stake.
    function enroll(uint256 agentId, uint256 stake) external {
        if (agentId == 0) revert ZeroAgentId();
        if (_enrolments[msg.sender].agentId != 0) revert AlreadyEnrolled(msg.sender);

        address bound = minerOf[agentId];
        if (bound != address(0)) revert AgentAlreadyBound(agentId, bound);
        if (!identityRegistry.isAuthorizedOrOwner(msg.sender, agentId)) {
            revert NotAuthorizedForAgent(msg.sender, agentId);
        }
        if (stake < minStake) revert StakeBelowMinimum(stake, minStake);

        _enrolments[msg.sender] = Enrolment({agentId: agentId, stake: stake, lockedUntil: 0});
        minerOf[agentId] = msg.sender;

        vault.deposit(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, stake);
        emit Enrolled(msg.sender, agentId, stake);
    }

    /// @notice Tops up an existing stake.
    function addStake(uint256 amount) external {
        Enrolment storage e = _enrolments[msg.sender];
        if (e.agentId == 0) revert NotEnrolled(msg.sender);
        e.stake += amount;
        vault.deposit(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, amount);
        emit StakeIncreased(msg.sender, amount, e.stake);
    }

    /// @notice Called by the tournament when a miner commits, so stake stays at risk for the
    ///         duration of the round it is backing.
    function lockUntil(address miner, uint64 until) external {
        if (msg.sender != consumer) revert NotConsumer();
        Enrolment storage e = _enrolments[miner];
        if (e.agentId == 0) revert NotEnrolled(miner);
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
        if (e.agentId == 0) revert NotEnrolled(msg.sender);
        if (block.timestamp < e.lockedUntil) revert StakeLockedUntil(e.lockedUntil);

        delete _enrolments[msg.sender];
        delete minerOf[e.agentId];

        vault.payOut(KIND_STAKE, bytes32(uint256(uint160(msg.sender))), msg.sender, e.stake);
        emit Withdrawn(msg.sender, e.agentId, e.stake);
    }

    /// @notice Reverts unless `miner` is enrolled; returns the bound agent id.
    function requireEnrolled(address miner) external view returns (uint256 agentId) {
        agentId = _enrolments[miner].agentId;
        if (agentId == 0) revert NotEnrolled(miner);
    }

    function enrolmentOf(address miner) external view returns (Enrolment memory) {
        return _enrolments[miner];
    }
}
