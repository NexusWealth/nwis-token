// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Nonces.sol"; 

/**
 * @title NexusWealthToken
 * @notice ERC20 with governance, bridge, blacklist, blacklist operators, supported chains, and supply cap.
 * Compatible with OpenZeppelin Contracts v5.x
 */
contract NexusWealthToken is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    ERC20Permit,
    ERC20Votes,
    Ownable,
    ReentrancyGuard
{
    uint8 private _customDecimals;
    uint256 public maxSupply;
    uint256 public totalMinted;
    uint256 public totalBurned;

    mapping(address => bool) public isBlacklisted;

    uint256 public maxBridgeAmount;
    uint256 public bridgeFee;
    uint256 public bridgeFeesCollected;
    mapping(address => bool) public bridgeOperators;

    // === Blacklist Operators ===
    mapping(address => bool) public blacklistOperators;
    event BlacklistOperatorUpdated(address indexed operator, bool status);

    // === Supported Chains ===
    mapping(uint256 => bool) public supportedChains;
    event SupportedChainUpdated(uint256 indexed chainId, bool supported);

    struct BridgeRequest {
        address from;
        address to;
        uint256 amount;
        uint256 fee;
        bool processed;
        bool canceled;
    }

    mapping(uint256 => BridgeRequest) public bridgeRequests;
    uint256 public bridgeRequestCount;

    enum VoteType { Against, For, Abstain }

    struct Proposal {
        address proposer;
        string  description;
        uint256 snapshotBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool    executed;
        bool    canceled;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalCount;

    uint256 public proposalThreshold;
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public quorumNumerator;
    uint256 public constant QUORUM_DENOMINATOR = 10_000;

    event BridgeInitiated(uint256 indexed requestId, address indexed from, uint256 amount, uint256 fee);
    event BridgeProcessed(uint256 indexed requestId, address indexed to, uint256 amount);
    event BridgeCanceled(uint256 indexed requestId, address indexed by);
    event BridgeFeesWithdrawn(address indexed to, uint256 amount);

    event ProposalCreated(uint256 indexed id, address indexed proposer, uint256 snapshotBlock, uint256 startBlock, uint256 endBlock, string description);
    event VoteCast(uint256 indexed id, address indexed voter, VoteType support, uint256 weight);
    event ProposalCanceled(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 _maxSupply,
        uint256 _initialSupply
    )
        ERC20(name, symbol)
        ERC20Permit(name)
        Ownable(msg.sender)
    {
        _customDecimals = decimals_;
        maxSupply = _maxSupply * 10 ** _customDecimals;
        require(_initialSupply * 10 ** _customDecimals <= maxSupply, "Initial supply exceeds max");
        _mint(msg.sender, _initialSupply * 10 ** _customDecimals);
        totalMinted = _initialSupply * 10 ** _customDecimals;

        maxBridgeAmount = 50_000_000 * 10 ** _customDecimals;
        bridgeFee = 0;

        proposalThreshold = 0;
        votingDelay = 0;
        votingPeriod = 45_000;
        quorumNumerator = 400;
    }

    // ===== Admin setters =====
    function setBridgeOperator(address operator, bool status) external onlyOwner { bridgeOperators[operator] = status; }
    function setBridgeFee(uint256 newFeeWei) external onlyOwner { bridgeFee = newFeeWei; }
    function setBlacklistOperator(address operator, bool status) external onlyOwner {
        blacklistOperators[operator] = status;
        emit BlacklistOperatorUpdated(operator, status);
    }
    function setSupportedChain(uint256 chainId, bool status) external onlyOwner {
        supportedChains[chainId] = status;
        emit SupportedChainUpdated(chainId, status);
    }

    // ===== Blacklist management =====
    modifier onlyBlacklistAdmin() {
        require(msg.sender == owner() || blacklistOperators[msg.sender], "Not authorized");
        _;
    }

    function setBlacklistStatus(address user, bool status) external onlyBlacklistAdmin {
        isBlacklisted[user] = status;
    }

    // ===== ERC20 controls =====
    function decimals() public view override returns (uint8) { return _customDecimals; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        _mint(to, amount);
        totalMinted += amount;
    }

    // ===== Bridge =====
    function initiateBridge(address to, uint256 amount, uint256 targetChainId) external payable nonReentrant whenNotPaused {
        require(!isBlacklisted[msg.sender], "Blacklisted");
        require(amount <= maxBridgeAmount, "Exceeds bridge cap");
        require(msg.value >= bridgeFee, "Insufficient fee");
        require(supportedChains[targetChainId], "Chain not supported");

        _burn(msg.sender, amount);
        totalBurned += amount;

        bridgeRequestCount++;
        bridgeRequests[bridgeRequestCount] = BridgeRequest(msg.sender, to, amount, msg.value, false, false);

        bridgeFeesCollected += msg.value;
        emit BridgeInitiated(bridgeRequestCount, msg.sender, amount, msg.value);
    }

    function processBridge(uint256 requestId) external nonReentrant {
        require(bridgeOperators[msg.sender], "Not operator");
        BridgeRequest storage r = bridgeRequests[requestId];
        require(!r.processed && !r.canceled, "Finalized");

        r.processed = true;
        _mint(r.to, r.amount);
        totalMinted += r.amount;
        emit BridgeProcessed(requestId, r.to, r.amount);
    }

    function cancelBridge(uint256 requestId) external {
        BridgeRequest storage r = bridgeRequests[requestId];
        require(r.from != address(0), "Invalid");
        require(!r.processed && !r.canceled, "Finalized");
        require(msg.sender == r.from || msg.sender == owner(), "Not authorized");
        r.canceled = true;
        emit BridgeCanceled(requestId, msg.sender);
    }

    function withdrawBridgeFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address");
        require(amount <= bridgeFeesCollected, "Insufficient");
        bridgeFeesCollected -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit BridgeFeesWithdrawn(to, amount);
    }

    // ===== Governance API =====
    function quorum(uint256 ) public view returns (uint256) {
        return (totalSupply() * quorumNumerator) / QUORUM_DENOMINATOR;
    }

    function setVotingParams(uint256 _threshold, uint256 _delay, uint256 _period, uint256 _quorumNumerator)
        external
        onlyOwner
    {
        require(_quorumNumerator <= QUORUM_DENOMINATOR, "quorum too high");
        proposalThreshold = _threshold;
        votingDelay = _delay;
        votingPeriod = _period;
        quorumNumerator = _quorumNumerator;
    }

    function createProposal(string calldata description) external returns (uint256 id) {
        require(getPastVotes(msg.sender, block.number - 1) >= proposalThreshold, "threshold");
        id = ++proposalCount;
        uint256 snap = block.number;
        uint256 start = snap + votingDelay;
        uint256 end = start + votingPeriod;
        proposals[id] = Proposal(msg.sender, description, snap, start, end, 0, 0, 0, false, false);
        emit ProposalCreated(id, msg.sender, snap, start, end, description);
    }

    function castVote(uint256 id, VoteType support) external {
        Proposal storage p = proposals[id];
        require(p.proposer != address(0), "no proposal");
        require(!p.canceled && !p.executed, "finalized");
        require(block.number >= p.startBlock && block.number <= p.endBlock, "voting closed");
        require(!hasVoted[id][msg.sender], "already voted");

        uint256 weight = getPastVotes(msg.sender, p.snapshotBlock);
        require(weight > 0, "no voting power");
        hasVoted[id][msg.sender] = true;

        if (support == VoteType.For) p.forVotes += weight;
        else if (support == VoteType.Against) p.againstVotes += weight;
        else p.abstainVotes += weight;

        emit VoteCast(id, msg.sender, support, weight);
    }

    function state(uint256 id) public view returns (string memory) {
        Proposal storage p = proposals[id];
        if (p.canceled) return "Canceled";
        if (block.number < p.startBlock) return "Pending";
        if (block.number <= p.endBlock) return "Active";
        uint256 turnout = p.forVotes + p.againstVotes + p.abstainVotes;
        if (turnout < quorum(p.snapshotBlock)) return "Defeated";
        if (p.forVotes <= p.againstVotes) return "Defeated";
        if (p.executed) return "Executed";
        return "Succeeded";
    }

    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.canceled && !p.executed, "finalized");
        require(msg.sender == p.proposer || msg.sender == owner(), "not auth");
        p.canceled = true;
        emit ProposalCanceled(id);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.canceled && !p.executed, "finalized");
        require(block.number > p.endBlock, "still active");
        uint256 turnout = p.forVotes + p.againstVotes + p.abstainVotes;
        require(turnout >= quorum(p.snapshotBlock), "no quorum");
        require(p.forVotes > p.againstVotes, "not passed");
        p.executed = true;
        emit ProposalExecuted(id);
    }

    // ===== Required overrides =====
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        if (from != address(0)) require(!isBlacklisted[from], "Sender blacklisted");
        if (to != address(0)) require(!isBlacklisted[to], "Recipient blacklisted");
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
