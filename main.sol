// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Terminus Vanguard Execution Ledger
/// @notice On-chain mission registry for autonomous task dispatch with phased execution windows and guardian oversight.
/// @dev Deployed payload hashes and target bindings; no direct ETH custody in mission slots.

error TX5_NotExecutor();
error TX5_NotOverseer();
error TX5_NotGuardian();
error TX5_ReentrancyLock();
error TX5_RegistryPaused();
error TX5_InvalidMissionId();
error TX5_InvalidSlotIndex();
error TX5_MissionAlreadyTerminated();
error TX5_MissionNotQueued();
error TX5_DeadlineElapsed();
error TX5_DeadlineNotReached();
error TX5_CooldownActive();
error TX5_ZeroPayload();
error TX5_BatchLengthMismatch();
error TX5_BatchTooLarge();
error TX5_MaxMissionsReached();
error TX5_InvalidPhase();
error TX5_TargetAlreadyBound();
error TX5_WithdrawOverCap();
error TX5_ZeroAmount();
error TX5_InvalidBound();

event MissionQueued(uint256 indexed missionId, bytes32 payloadHash, uint256 deadlineBlock, address indexed executor);
event MissionExecuted(uint256 indexed missionId, uint256 executedAtBlock, bytes32 resultHash);
event MissionTerminated(uint256 indexed missionId, uint256 atBlock, address indexed guardian);
event TargetBound(uint256 indexed missionId, address indexed target, uint256 slotIndex);
event OverseerRotated(address indexed previous, address indexed next);
event RegistryPauseToggled(bool paused);
event WithdrawalProcessed(address indexed to, uint256 amountWei);
event PhaseAdvanced(uint256 indexed missionId, uint8 fromPhase, uint8 toPhase);

uint256 constant TX5_MAX_MISSIONS = 88_888;
uint256 constant TX5_COOLDOWN_BLOCKS = 12;
uint256 constant TX5_MAX_BATCH_QUEUE = 64;
uint256 constant TX5_WITHDRAW_CAP_WEI = 3 ether;
uint256 constant TX5_VERSION = 5;

struct MissionSlot {
    bytes32 payloadHash;
    uint256 deadlineBlock;
    uint256 queuedBlock;
    uint8 phase;
    bool terminated;
    address boundTarget;
}

contract T5_execute {

    address public immutable executor;
    address public immutable overseer;
    address public immutable guardian;

    uint256 public immutable genesisBlock;
    uint256 private _reentrancyLock;
    bool public registryPaused;
    uint256 private _nextMissionId;
    uint256 private _totalWithdrawnWei;
    mapping(uint256 => MissionSlot) private _missions;
    mapping(uint256 => uint256) private _lastExecutedBlock;
    mapping(address => uint256) private _executionCount;

    modifier onlyExecutor() {
        if (msg.sender != executor) revert TX5_NotExecutor();
        _;
