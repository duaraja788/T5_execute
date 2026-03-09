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
    }

    modifier onlyOverseer() {
        if (msg.sender != overseer) revert TX5_NotOverseer();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert TX5_NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (registryPaused) revert TX5_RegistryPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert TX5_ReentrancyLock();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor() {
        executor = 0x9D7f2E4a6C8b0d2F4a6B8c0D2e4F6a8B0c2D4e6;
        overseer = 0x3E5a7C9e1B3d5F7a9c1E3b5D7f9A1c3E5b7D9f1;
        guardian = 0xB2d4F6a8C0e2A4b6D8f0C2e4A6b8D0f2C4e6A8;
        genesisBlock = block.number;
    }

    function queueMission(bytes32 payloadHash, uint256 deadlineBlock) external onlyExecutor whenNotPaused nonReentrant returns (uint256 missionId) {
        if (payloadHash == bytes32(0)) revert TX5_ZeroPayload();
        if (_nextMissionId >= TX5_MAX_MISSIONS) revert TX5_MaxMissionsReached();
        if (deadlineBlock <= block.number) revert TX5_DeadlineElapsed();
        missionId = _nextMissionId;
        unchecked { ++_nextMissionId; }
        _missions[missionId] = MissionSlot({
            payloadHash: payloadHash,
            deadlineBlock: deadlineBlock,
            queuedBlock: block.number,
            phase: 1,
            terminated: false,
            boundTarget: address(0)
        });
        emit MissionQueued(missionId, payloadHash, deadlineBlock, msg.sender);
    }

    function queueMissionBatch(bytes32[] calldata payloadHashes, uint256[] calldata deadlineBlocks) external onlyExecutor whenNotPaused nonReentrant returns (uint256 startId, uint256 count) {
        uint256 n = payloadHashes.length;
        if (n == 0 || n != deadlineBlocks.length) revert TX5_BatchLengthMismatch();
        if (n > TX5_MAX_BATCH_QUEUE) revert TX5_BatchTooLarge();
        if (_nextMissionId + n > TX5_MAX_MISSIONS) revert TX5_MaxMissionsReached();
        startId = _nextMissionId;
        uint256 blk = block.number;
        for (uint256 i; i < n; ) {
            bytes32 ph = payloadHashes[i];
            uint256 dl = deadlineBlocks[i];
            if (ph == bytes32(0) || dl <= blk) revert TX5_ZeroPayload();
            _missions[_nextMissionId] = MissionSlot({
                payloadHash: ph,
                deadlineBlock: dl,
                queuedBlock: blk,
                phase: 1,
                terminated: false,
                boundTarget: address(0)
            });
            emit MissionQueued(_nextMissionId, ph, dl, msg.sender);
            unchecked { ++_nextMissionId; ++i; }
        }
        count = n;
    }

    function executeMission(uint256 missionId, bytes32 resultHash) external onlyExecutor whenNotPaused nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage slot = _missions[missionId];
        if (slot.terminated) revert TX5_MissionAlreadyTerminated();
        if (slot.payloadHash == bytes32(0)) revert TX5_MissionNotQueued();
        if (block.number > slot.deadlineBlock) revert TX5_DeadlineElapsed();
        uint256 lastExec = _lastExecutedBlock[missionId];
        if (lastExec != 0 && block.number < lastExec + TX5_COOLDOWN_BLOCKS) revert TX5_CooldownActive();
        _lastExecutedBlock[missionId] = block.number;
        unchecked { _executionCount[msg.sender]++; }
        uint8 fromPhase = slot.phase;
        slot.phase = 2;
        emit MissionExecuted(missionId, block.number, resultHash);
        emit PhaseAdvanced(missionId, fromPhase, 2);
    }

    function terminateMission(uint256 missionId) external onlyGuardian nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage slot = _missions[missionId];
        if (slot.terminated) revert TX5_MissionAlreadyTerminated();
        slot.terminated = true;
        slot.phase = 3;
        emit MissionTerminated(missionId, block.number, msg.sender);
    }

    function bindTarget(uint256 missionId, address target, uint256 slotIndex) external onlyOverseer whenNotPaused nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        if (target == address(0)) revert TX5_InvalidBound();
        MissionSlot storage slot = _missions[missionId];
        if (slot.terminated) revert TX5_MissionAlreadyTerminated();
        if (slot.boundTarget != address(0)) revert TX5_TargetAlreadyBound();
        slot.boundTarget = target;
        emit TargetBound(missionId, target, slotIndex);
    }

    function togglePause() external onlyGuardian {
        registryPaused = !registryPaused;
        emit RegistryPauseToggled(registryPaused);
    }

    function getMission(uint256 missionId) external view returns (
        bytes32 payloadHash,
        uint256 deadlineBlock,
        uint256 queuedBlock,
        uint8 phase,
        bool terminated,
        address boundTarget
    ) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage s = _missions[missionId];
        return (s.payloadHash, s.deadlineBlock, s.queuedBlock, s.phase, s.terminated, s.boundTarget);
    }

    function lastExecutedBlock(uint256 missionId) external view returns (uint256) {
        return _lastExecutedBlock[missionId];
    }

    function executionCountFor(address account) external view returns (uint256) {
        return _executionCount[account];
    }

    function nextMissionId() external view returns (uint256) {
        return _nextMissionId;
    }

    receive() external payable {}

    function withdrawTo(address to, uint256 amountWei) external onlyOverseer nonReentrant {
        if (to == address(0) || amountWei == 0) revert TX5_ZeroAmount();
        if (_totalWithdrawnWei + amountWei > TX5_WITHDRAW_CAP_WEI) revert TX5_WithdrawOverCap();
        _totalWithdrawnWei += amountWei;
        (bool ok,) = to.call{value: amountWei}("");
        if (!ok) revert TX5_WithdrawOverCap();
        emit WithdrawalProcessed(to, amountWei);
    }

    function totalWithdrawnWei() external view returns (uint256) {
        return _totalWithdrawnWei;
    }

    function isMissionTerminated(uint256 missionId) external view returns (bool) {
        if (missionId >= _nextMissionId) return false;
        return _missions[missionId].terminated;
    }

    function isMissionExecutable(uint256 missionId) external view returns (bool) {
        if (missionId >= _nextMissionId) return false;
        MissionSlot storage s = _missions[missionId];
        if (s.terminated || s.payloadHash == bytes32(0)) return false;
        if (block.number > s.deadlineBlock) return false;
        uint256 last = _lastExecutedBlock[missionId];
        return last == 0 || block.number >= last + TX5_COOLDOWN_BLOCKS;
    }

    function payloadHashOf(uint256 missionId) external view returns (bytes32) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missions[missionId].payloadHash;
    }

    function deadlineBlockOf(uint256 missionId) external view returns (uint256) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missions[missionId].deadlineBlock;
    }

    function boundTargetOf(uint256 missionId) external view returns (address) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missions[missionId].boundTarget;
    }

    function phaseOf(uint256 missionId) external view returns (uint8) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missions[missionId].phase;
    }

    function queuedBlockOf(uint256 missionId) external view returns (uint256) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missions[missionId].queuedBlock;
    }

    bytes32 public constant TX5_NAMESPACE = keccak256("TerminusVanguard.T5");
    uint256 public constant TX5_PHASE_QUEUED = 1;
    uint256 public constant TX5_PHASE_EXECUTED = 2;
    uint256 public constant TX5_PHASE_TERMINATED = 3;

    function resolvePhaseName(uint8 phase) external pure returns (string memory) {
        if (phase == 1) return "QUEUED";
        if (phase == 2) return "EXECUTED";
        if (phase == 3) return "TERMINATED";
        return "UNKNOWN";
    }

    function missionSummary(uint256 missionId) external view returns (
        bool exists,
        bool terminated,
        bool pastDeadline,
        bool inCooldown
    ) {
        exists = missionId < _nextMissionId;
        if (!exists) return (false, false, false, false);
        MissionSlot storage s = _missions[missionId];
        terminated = s.terminated;
        pastDeadline = block.number > s.deadlineBlock;
        uint256 last = _lastExecutedBlock[missionId];
        inCooldown = last != 0 && block.number < last + TX5_COOLDOWN_BLOCKS;
    }

    function batchMissionSummaries(uint256[] calldata missionIds) external view returns (
        bool[] memory exists,
        bool[] memory terminated,
        bool[] memory pastDeadline,
        bool[] memory inCooldown
    ) {
        uint256 n = missionIds.length;
        if (n > 256) revert TX5_BatchTooLarge();
        exists = new bool[](n);
        terminated = new bool[](n);
        pastDeadline = new bool[](n);
        inCooldown = new bool[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            exists[i] = mid < _nextMissionId;
            if (exists[i]) {
                MissionSlot storage s = _missions[mid];
                terminated[i] = s.terminated;
                pastDeadline[i] = block.number > s.deadlineBlock;
                uint256 last = _lastExecutedBlock[mid];
                inCooldown[i] = last != 0 && block.number < last + TX5_COOLDOWN_BLOCKS;
            }
            unchecked { ++i; }
        }
    }

    function slotsBetween(uint256 fromId, uint256 toId) external view returns (
        uint256[] memory missionIds,
        bytes32[] memory payloadHashes,
        uint256[] memory deadlineBlocks,
        uint8[] memory phases,
        bool[] memory terminatedFlags
    ) {
        if (fromId > toId || toId >= _nextMissionId) revert TX5_InvalidMissionId();
        uint256 n = toId - fromId + 1;
        if (n > 128) revert TX5_BatchTooLarge();
        missionIds = new uint256[](n);
        payloadHashes = new bytes32[](n);
        deadlineBlocks = new uint256[](n);
        phases = new uint8[](n);
        terminatedFlags = new bool[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = fromId + i;
            MissionSlot storage s = _missions[mid];
            missionIds[i] = mid;
            payloadHashes[i] = s.payloadHash;
            deadlineBlocks[i] = s.deadlineBlock;
            phases[i] = s.phase;
            terminatedFlags[i] = s.terminated;
            unchecked { ++i; }
        }
    }

    function advancePhase(uint256 missionId, uint8 newPhase) external onlyOverseer whenNotPaused nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        if (newPhase < 1 || newPhase > 3) revert TX5_InvalidPhase();
        MissionSlot storage slot = _missions[missionId];
        if (slot.terminated) revert TX5_MissionAlreadyTerminated();
        uint8 fromPhase = slot.phase;
        if (newPhase <= fromPhase) revert TX5_InvalidPhase();
        slot.phase = newPhase;
        emit PhaseAdvanced(missionId, fromPhase, newPhase);
    }

    function computePayloadHash(bytes calldata payload) external pure returns (bytes32) {
        return keccak256(payload);
    }

    function computeResultHash(bytes32 payloadHash, bytes32 executionDigest) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(payloadHash, executionDigest));
    }

    function version() external pure returns (uint256) {
        return TX5_VERSION;
    }

    function namespaceHash() external pure returns (bytes32) {
        return TX5_NAMESPACE;
    }

    function cooldownBlocks() external pure returns (uint256) {
        return TX5_COOLDOWN_BLOCKS;
    }

    function maxMissions() external pure returns (uint256) {
        return TX5_MAX_MISSIONS;
    }

    function withdrawCapWei() external pure returns (uint256) {
        return TX5_WITHDRAW_CAP_WEI;
    }

    function maxBatchQueue() external pure returns (uint256) {
        return TX5_MAX_BATCH_QUEUE;
    }

    function genesisBlockNumber() external view returns (uint256) {
        return genesisBlock;
    }

    function blocksSinceGenesis() external view returns (uint256) {
        return block.number - genesisBlock;
    }

    function missionCount() external view returns (uint256) {
        return _nextMissionId;
    }

    function remainingMissionSlots() external view returns (uint256) {
        return _nextMissionId >= TX5_MAX_MISSIONS ? 0 : TX5_MAX_MISSIONS - _nextMissionId;
    }

    function remainingWithdrawCap() external view returns (uint256) {
        uint256 cap = TX5_WITHDRAW_CAP_WEI;
        return _totalWithdrawnWei >= cap ? 0 : cap - _totalWithdrawnWei;
    }

    function executorAddress() external view returns (address) {
        return executor;
    }

    function overseerAddress() external view returns (address) {
        return overseer;
    }

    function guardianAddress() external view returns (address) {
        return guardian;
    }

    function isPaused() external view returns (bool) {
        return registryPaused;
    }

    function checkCooldown(uint256 missionId) external view returns (bool inCooldown, uint256 blocksRemaining) {
        if (missionId >= _nextMissionId) return (true, type(uint256).max);
        uint256 last = _lastExecutedBlock[missionId];
