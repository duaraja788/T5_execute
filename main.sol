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
        if (last == 0) return (false, 0);
        uint256 windowEnd = last + TX5_COOLDOWN_BLOCKS;
        if (block.number >= windowEnd) return (false, 0);
        return (true, windowEnd - block.number);
    }

    function getMissionFull(uint256 missionId) external view returns (
        bytes32 payloadHash,
        uint256 deadlineBlock,
        uint256 queuedBlock,
        uint8 phase,
        bool terminated,
        address boundTarget,
        uint256 lastExecutedBlockNum
    ) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage s = _missions[missionId];
        return (
            s.payloadHash,
            s.deadlineBlock,
            s.queuedBlock,
            s.phase,
            s.terminated,
            s.boundTarget,
            _lastExecutedBlock[missionId]
        );
    }

    function hashMissionPayload(bytes32 a, bytes32 b, bytes32 c) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, c));
    }

    function hashMissionPayloadMany(bytes32[] calldata parts) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(parts));
    }

    function validateDeadline(uint256 missionId, uint256 asOfBlock) external view returns (bool valid) {
        if (missionId >= _nextMissionId) return false;
        return _missions[missionId].deadlineBlock > asOfBlock;
    }

    function validatePhaseTransition(uint8 fromPhase, uint8 toPhase) external pure returns (bool valid) {
        return toPhase > fromPhase && fromPhase >= 1 && fromPhase <= 3 && toPhase >= 1 && toPhase <= 3;
    }

    uint256 private _auxCounter;

    function auxIncrement() external onlyExecutor nonReentrant returns (uint256) {
        unchecked { return ++_auxCounter; }
    }

    function auxCounter() external view returns (uint256) {
        return _auxCounter;
    }

    mapping(bytes32 => uint256) private _payloadToFirstMissionId;

    function firstMissionIdForPayload(bytes32 payloadHash) external view returns (uint256) {
        return _payloadToFirstMissionId[payloadHash];
    }

    function registerPayloadToMission(bytes32 payloadHash, uint256 missionId) external onlyOverseer nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        if (_missions[missionId].payloadHash != payloadHash) revert TX5_InvalidMissionId();
        if (_payloadToFirstMissionId[payloadHash] == 0) {
            _payloadToFirstMissionId[payloadHash] = missionId;
        }
    }

    function getConfig() external view returns (
        uint256 maxMissions_,
        uint256 cooldownBlocks_,
        uint256 maxBatchQueue_,
        uint256 withdrawCapWei_,
        uint256 version_
    ) {
        return (TX5_MAX_MISSIONS, TX5_COOLDOWN_BLOCKS, TX5_MAX_BATCH_QUEUE, TX5_WITHDRAW_CAP_WEI, TX5_VERSION);
    }

    function executorRoleHash() external pure returns (bytes32) {
        return keccak256("EXECUTOR");
    }

    function overseerRoleHash() external pure returns (bytes32) {
        return keccak256("OVERSEER");
    }

    function guardianRoleHash() external pure returns (bytes32) {
        return keccak256("GUARDIAN");
    }

    event AuxCounterIncremented(uint256 newValue);

    function incrementAndEmitAux() external onlyExecutor nonReentrant {
        unchecked { ++_auxCounter; }
        emit AuxCounterIncremented(_auxCounter);
    }

    function multiIncrementAux(uint256 times) external onlyExecutor nonReentrant returns (uint256 endValue) {
        if (times == 0 || times > 100) revert TX5_InvalidPhase();
        for (uint256 i; i < times; ) {
            unchecked { ++_auxCounter; ++i; }
        }
        endValue = _auxCounter;
        emit AuxCounterIncremented(endValue);
    }

    function getRoleAddresses() external view returns (address exec, address over, address guard) {
        return (executor, overseer, guardian);
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }

    function domainSeparatorV5() external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "TerminusVanguard.T5",
            block.chainid,
            address(this)
        ));
    }

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    function eip712DomainTypeHash() external pure returns (bytes32) {
        return EIP712_DOMAIN_TYPEHASH;
    }

    struct MissionDigest {
        uint256 missionId;
        bytes32 payloadHash;
        uint256 deadlineBlock;
    }

    function hashMissionDigest(MissionDigest calldata d) external pure returns (bytes32) {
        return keccak256(abi.encode(d.missionId, d.payloadHash, d.deadlineBlock));
    }

    function requireMissionExists(uint256 missionId) external view {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
    }

    function requireMissionNotTerminated(uint256 missionId) external view {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        if (_missions[missionId].terminated) revert TX5_MissionAlreadyTerminated();
    }

    function requireMissionExecutable(uint256 missionId) external view {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage s = _missions[missionId];
        if (s.terminated || s.payloadHash == bytes32(0)) revert TX5_MissionNotQueued();
        if (block.number > s.deadlineBlock) revert TX5_DeadlineElapsed();
        uint256 last = _lastExecutedBlock[missionId];
        if (last != 0 && block.number < last + TX5_COOLDOWN_BLOCKS) revert TX5_CooldownActive();
    }

    mapping(uint256 => bytes32) private _resultHashes;

    function setResultHash(uint256 missionId, bytes32 resultHash) external onlyExecutor nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        if (_missions[missionId].terminated) revert TX5_MissionAlreadyTerminated();
        _resultHashes[missionId] = resultHash;
    }

    function resultHashOf(uint256 missionId) external view returns (bytes32) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _resultHashes[missionId];
    }

    function executeMissionWithResult(uint256 missionId, bytes32 resultHash) external onlyExecutor whenNotPaused nonReentrant {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        MissionSlot storage slot = _missions[missionId];
        if (slot.terminated) revert TX5_MissionAlreadyTerminated();
        if (slot.payloadHash == bytes32(0)) revert TX5_MissionNotQueued();
        if (block.number > slot.deadlineBlock) revert TX5_DeadlineElapsed();
        uint256 lastExec = _lastExecutedBlock[missionId];
        if (lastExec != 0 && block.number < lastExec + TX5_COOLDOWN_BLOCKS) revert TX5_CooldownActive();
        _lastExecutedBlock[missionId] = block.number;
        _resultHashes[missionId] = resultHash;
        unchecked { _executionCount[msg.sender]++; }
        uint8 fromPhase = slot.phase;
        slot.phase = 2;
        emit MissionExecuted(missionId, block.number, resultHash);
        emit PhaseAdvanced(missionId, fromPhase, 2);
    }

    function batchSetResultHashes(uint256[] calldata missionIds, bytes32[] calldata resultHashes) external onlyExecutor nonReentrant {
        uint256 n = missionIds.length;
        if (n != resultHashes.length || n == 0 || n > 32) revert TX5_BatchLengthMismatch();
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            if (mid >= _nextMissionId) revert TX5_InvalidMissionId();
            if (!_missions[mid].terminated) _resultHashes[mid] = resultHashes[i];
            unchecked { ++i; }
        }
    }

    function slotExists(uint256 missionId) external view returns (bool) {
        return missionId < _nextMissionId;
    }

    function totalExecutionCount() external view returns (uint256 total) {
        return _executionCount[executor] + _executionCount[overseer];
    }

    function getMissionIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        if (limit > 100) revert TX5_BatchTooLarge();
        uint256 end = offset + limit;
        if (end > _nextMissionId) end = _nextMissionId;
        if (offset >= _nextMissionId) return new uint256[](0);
        uint256 n = end - offset;
        ids = new uint256[](n);
        for (uint256 i; i < n; ) {
            ids[i] = offset + i;
            unchecked { ++i; }
        }
    }

    function countTerminated() external view returns (uint256 count) {
        for (uint256 i; i < _nextMissionId; ) {
            if (_missions[i].terminated) unchecked { ++count; }
            unchecked { ++i; }
        }
    }

    function countByPhase(uint8 phase) external view returns (uint256 count) {
        for (uint256 i; i < _nextMissionId; ) {
            if (_missions[i].phase == phase && !_missions[i].terminated) unchecked { ++count; }
            unchecked { ++i; }
        }
    }

    function getMissionDeadlines(uint256[] calldata missionIds) external view returns (uint256[] memory deadlines) {
        uint256 n = missionIds.length;
        if (n > 64) revert TX5_BatchTooLarge();
        deadlines = new uint256[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            if (mid < _nextMissionId) deadlines[i] = _missions[mid].deadlineBlock;
            else deadlines[i] = 0;
            unchecked { ++i; }
        }
    }

    function getMissionPayloadHashes(uint256[] calldata missionIds) external view returns (bytes32[] memory hashes) {
        uint256 n = missionIds.length;
        if (n > 64) revert TX5_BatchTooLarge();
        hashes = new bytes32[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            if (mid < _nextMissionId) hashes[i] = _missions[mid].payloadHash;
            unchecked { ++i; }
        }
    }

    function isWithinDeadline(uint256 missionId) external view returns (bool) {
        if (missionId >= _nextMissionId) return false;
        return block.number <= _missions[missionId].deadlineBlock;
    }

    function blocksUntilDeadline(uint256 missionId) external view returns (uint256 blocks) {
        if (missionId >= _nextMissionId) return 0;
        uint256 dl = _missions[missionId].deadlineBlock;
        return block.number >= dl ? 0 : dl - block.number;
    }

    function missionAge(uint256 missionId) external view returns (uint256 blocks) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        uint256 q = _missions[missionId].queuedBlock;
        return block.number - q;
    }

    function missionAgesBatch(uint256[] calldata missionIds) external view returns (uint256[] memory ages) {
        uint256 n = missionIds.length;
        if (n > 64) revert TX5_BatchTooLarge();
        ages = new uint256[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            if (mid < _nextMissionId) ages[i] = block.number - _missions[mid].queuedBlock;
            unchecked { ++i; }
        }
    }

    function _requireValidMission(uint256 missionId) internal view {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
    }

    function _missionSlot(uint256 missionId) internal view returns (MissionSlot storage) {
        _requireValidMission(missionId);
        return _missions[missionId];
    }

    function internalPayloadHash(uint256 missionId) external view returns (bytes32) {
        return _missions[missionId].payloadHash;
    }

    function internalDeadline(uint256 missionId) external view returns (uint256) {
        return _missions[missionId].deadlineBlock;
    }

    function getMissionPhaseName(uint256 missionId) external view returns (string memory) {
        if (missionId >= _nextMissionId) return "NONE";
        return resolvePhaseName(_missions[missionId].phase);
    }

    function allPhaseNames() external pure returns (string memory p1, string memory p2, string memory p3) {
        return ("QUEUED", "EXECUTED", "TERMINATED");
    }

    function chainId() external view returns (uint256) {
        return block.chainid;
    }

    function blockNumber() external view returns (uint256) {
        return block.number;
    }

    function timestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function canWithdraw(uint256 amountWei) external view returns (bool) {
        return _totalWithdrawnWei + amountWei <= TX5_WITHDRAW_CAP_WEI;
    }

    function withdrawableRemaining() external view returns (uint256) {
        uint256 cap = TX5_WITHDRAW_CAP_WEI;
        return _totalWithdrawnWei >= cap ? 0 : cap - _totalWithdrawnWei;
    }

    function isExecutor(address account) external view returns (bool) {
        return account == executor;
    }

    function isOverseer(address account) external view returns (bool) {
        return account == overseer;
    }

    function isGuardian(address account) external view returns (bool) {
        return account == guardian;
    }

    function hasRole(bytes32 roleHash, address account) external view returns (bool) {
        if (roleHash == keccak256("EXECUTOR")) return account == executor;
        if (roleHash == keccak256("OVERSEER")) return account == overseer;
        if (roleHash == keccak256("GUARDIAN")) return account == guardian;
        return false;
    }

    function getMissionIdsInRange(uint256 start, uint256 end) external view returns (uint256[] memory) {
        if (start > end || end >= _nextMissionId) revert TX5_InvalidMissionId();
        uint256 n = end - start + 1;
        if (n > 80) revert TX5_BatchTooLarge();
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ) {
            ids[i] = start + i;
            unchecked { ++i; }
        }
        return ids;
    }

    function getMissionStatus(uint256 missionId) external view returns (
        bool exists,
        bool queued,
        bool executed,
        bool terminated,
        uint256 blocksLeft
    ) {
        exists = missionId < _nextMissionId;
        if (!exists) return (false, false, false, false, 0);
        MissionSlot storage s = _missions[missionId];
        queued = s.payloadHash != bytes32(0);
        executed = s.phase >= 2;
        terminated = s.terminated;
        blocksLeft = block.number >= s.deadlineBlock ? 0 : s.deadlineBlock - block.number;
    }

    function getMissionStatusBatch(uint256[] calldata missionIds) external view returns (
        bool[] memory exists,
        bool[] memory queued,
        bool[] memory executed,
        bool[] memory terminated,
        uint256[] memory blocksLeft
    ) {
        uint256 n = missionIds.length;
        if (n > 64) revert TX5_BatchTooLarge();
        exists = new bool[](n);
        queued = new bool[](n);
        executed = new bool[](n);
        terminated = new bool[](n);
        blocksLeft = new uint256[](n);
        for (uint256 i; i < n; ) {
            uint256 mid = missionIds[i];
            exists[i] = mid < _nextMissionId;
            if (exists[i]) {
                MissionSlot storage s = _missions[mid];
                queued[i] = s.payloadHash != bytes32(0);
                executed[i] = s.phase >= 2;
                terminated[i] = s.terminated;
                blocksLeft[i] = block.number >= s.deadlineBlock ? 0 : s.deadlineBlock - block.number;
            }
            unchecked { ++i; }
        }
    }

    function findFirstExecutableMission(uint256 fromId, uint256 toId) external view returns (uint256 missionId, bool found) {
        if (fromId > toId || toId >= _nextMissionId) return (0, false);
        for (uint256 i = fromId; i <= toId; ) {
            MissionSlot storage s = _missions[i];
            if (!s.terminated && s.payloadHash != bytes32(0) && block.number <= s.deadlineBlock) {
                uint256 last = _lastExecutedBlock[i];
                if (last == 0 || block.number >= last + TX5_COOLDOWN_BLOCKS) return (i, true);
            }
            unchecked { ++i; }
        }
        return (0, false);
    }

    function countExecutableInRange(uint256 fromId, uint256 toId) external view returns (uint256 count) {
        if (fromId > toId || toId >= _nextMissionId) return 0;
        for (uint256 i = fromId; i <= toId; ) {
            MissionSlot storage s = _missions[i];
            if (!s.terminated && s.payloadHash != bytes32(0) && block.number <= s.deadlineBlock) {
                uint256 last = _lastExecutedBlock[i];
                if (last == 0 || block.number >= last + TX5_COOLDOWN_BLOCKS) unchecked { ++count; }
            }
            unchecked { ++i; }
        }
    }

    function getExecutableMissionIds(uint256 fromId, uint256 limit) external view returns (uint256[] memory ids) {
        if (limit > 50) revert TX5_BatchTooLarge();
        uint256[] memory temp = new uint256[](limit);
        uint256 count;
        for (uint256 i = fromId; i < _nextMissionId && count < limit; ) {
            MissionSlot storage s = _missions[i];
            if (!s.terminated && s.payloadHash != bytes32(0) && block.number <= s.deadlineBlock) {
                uint256 last = _lastExecutedBlock[i];
                if (last == 0 || block.number >= last + TX5_COOLDOWN_BLOCKS) {
                    temp[count] = i;
                    unchecked { ++count; }
                }
            }
            unchecked { ++i; }
        }
        ids = new uint256[](count);
        for (uint256 j; j < count; ) {
            ids[j] = temp[j];
            unchecked { ++j; }
        }
    }

    function hashPayloadWithNonce(bytes32 payloadHash, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(payloadHash, nonce));
    }

    function hashPayloadWithNonceAndSender(bytes32 payloadHash, uint256 nonce, address sender) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(payloadHash, nonce, sender));
    }

    function combineHashes(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function combineHashesThree(bytes32 a, bytes32 b, bytes32 c) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, c));
    }

    bytes32 public constant MISSION_QUEUED_TYPEHASH = keccak256("MissionQueued(uint256 missionId,bytes32 payloadHash,uint256 deadlineBlock)");

    function missionQueuedTypeHash() external pure returns (bytes32) {
        return MISSION_QUEUED_TYPEHASH;
    }

    function encodeMissionQueued(uint256 missionId, bytes32 payloadHash, uint256 deadlineBlock) external pure returns (bytes memory) {
        return abi.encode(missionId, payloadHash, deadlineBlock);
    }

    function hashEncodedMissionQueued(bytes memory data) external pure returns (bytes32) {
        return keccak256(data);
    }

    mapping(uint256 => uint256) private _missionNonce;

    function nonceOf(uint256 missionId) external view returns (uint256) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        return _missionNonce[missionId];
    }

    function incrementNonce(uint256 missionId) external onlyExecutor nonReentrant returns (uint256 newNonce) {
        if (missionId >= _nextMissionId) revert TX5_InvalidMissionId();
        newNonce = _missionNonce[missionId] + 1;
