// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title NexusWealth Investment Solutions Token
 * @dev ERC20 token with advanced features including:
 * - Timestamp-based voting system
 * - Permit functionality (EIP-2612)
 * - Custom cross-chain bridging
 * - Blacklist functionality
 * - Pausable functionality
 * - Burnable functionality
 */
contract NexusWealthToken is ERC20, ERC20Burnable, ERC20Pausable, ERC20Permit, Ownable, ReentrancyGuard {
    using Checkpoints for Checkpoints.Trace224;
    
    // Token configuration
    uint256 public immutable maxSupply;
    uint256 public totalMinted;
    uint256 public totalBurned;
    
    // Blacklist functionality
    mapping(address => bool) public isBlacklisted;
    mapping(address => bool) public isBlacklistOperator;
    
    // Voting system
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startTime;
        uint256 endTime;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
    }
    
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public quorum;
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public minProposalTokens;
    
    // Cross-chain bridging
    struct BridgeRequest {
        address from;
        uint256 amount;
        uint256 targetChainId;
        uint256 timestamp;
        bytes32 requestHash;
        bool processed;
        bool canceled;
    }
    
    mapping(uint256 => BridgeRequest) public bridgeRequests;
    uint256 public bridgeRequestCount;
    mapping(address => bool) public bridgeOperators;
    mapping(uint256 => bool) public supportedChains;
    uint256 public bridgeFee;
    uint256 public maxBridgeAmount;
    uint256 public bridgeFeesCollected;
    
    // Events
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event BlacklistOperatorUpdated(address indexed operator, bool isOperator);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 startTime, uint256 endTime);
    event VoteCast(address indexed voter, uint256 indexed proposalId, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event MinProposalTokensUpdated(uint256 newMinTokens);
    event BridgeRequestInitiated(uint256 indexed requestId, address indexed from, uint256 amount, uint256 targetChainId);
    event BridgeRequestProcessed(uint256 indexed requestId, address indexed to, uint256 amount, uint256 sourceChainId);
    event BridgeOperatorUpdated(address indexed operator, bool isOperator);
    event SupportedChainUpdated(uint256 indexed chainId, bool isSupported);
    event BridgeFeeUpdated(uint256 newFee);
    event BridgeLimitsUpdated(uint256 newMaxAmount);
    event BridgeFeesWithdrawn(address indexed to, uint256 amount);
    
    // Modifiers
    modifier onlyBlacklistOperator() {
        require(isBlacklistOperator[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    modifier onlyBridgeOperator() {
        require(bridgeOperators[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    modifier notBlacklisted(address account) {
        require(!isBlacklisted[account], "Account is blacklisted");
        _;
    }
    
    /**
     * @dev Constructor
     * @param name Token name
     * @param symbol Token symbol
     * @param decimals_ Token decimals
     * @param _maxSupply Maximum token supply
     * @param _initialSupply Initial token supply
     */
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 _maxSupply,
        uint256 _initialSupply
    ) ERC20(name, symbol) ERC20Permit(name) Ownable(msg.sender) {
        require(_maxSupply > 0, "Max supply must be greater than 0");
        require(_initialSupply <= _maxSupply, "Initial supply cannot exceed max supply");
        
        maxSupply = _maxSupply;
        
        // Set initial supply
        _mint(msg.sender, _initialSupply);
        totalMinted = _initialSupply;
        
        // Set voting parameters
        quorum = _maxSupply / 100; // 1% of max supply
        votingDelay = 1 days;
        votingPeriod = 7 days;
        minProposalTokens = _maxSupply / 1000; // 0.1% of max supply
        
        // Set bridge parameters
        maxBridgeAmount = 50_000_000 * 10**decimals_; // 50 million tokens
        bridgeFee = 0.001 ether; // 0.001 ETH fee
        
        // Set initial blacklist operators
        isBlacklistOperator[msg.sender] = true;
        
        // Set initial bridge operators
        bridgeOperators[msg.sender] = true;
        
        // Set supported chains (Ethereum mainnet and Sepolia)
        supportedChains[1] = true;    // Ethereum mainnet
        supportedChains[11155111] = true; // Sepolia testnet
    }
    
    /**
     * @dev Mint new tokens (owner only)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner notBlacklisted(to) {
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        require(to != address(0), "Cannot mint to zero address");
        
        _mint(to, amount);
        totalMinted += amount;
        
        emit TokensMinted(to, amount);
    }
    
    /**
     * @dev Burn tokens
     * @param amount Amount to burn
     */
    function burn(uint256 amount) public override {
        super.burn(amount);
        totalBurned += amount;
        emit TokensBurned(msg.sender, amount);
    }
    
    /**
     * @dev Burn tokens from specific address (owner only)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyOwner {
        super.burnFrom(from, amount);
        totalBurned += amount;
        emit TokensBurned(from, amount);
    }
    
    /**
     * @dev Pause token transfers (owner only)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause token transfers (owner only)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Set blacklist status for an account
     * @param account Address to blacklist/whitelist
     * @param isBlacklisted_ Blacklist status
     */
    function setBlacklistStatus(address account, bool isBlacklisted_) external onlyBlacklistOperator {
        isBlacklisted[account] = isBlacklisted_;
        emit BlacklistUpdated(account, isBlacklisted_);
    }
    
    /**
     * @dev Set blacklist operator status
     * @param operator Address to set as operator
     * @param isOperator_ Operator status
     */
    function setBlacklistOperator(address operator, bool isOperator_) external onlyOwner {
        isBlacklistOperator[operator] = isOperator_;
        emit BlacklistOperatorUpdated(operator, isOperator_);
    }
    
    /**
     * @dev Create a new proposal
     * @param description Proposal description
     */
    function createProposal(string memory description) external notBlacklisted(msg.sender) returns (uint256) {
        require(bytes(description).length > 0, "Description cannot be empty");
        require(balanceOf(msg.sender) >= minProposalTokens, "Insufficient tokens for proposal creation");
        
        uint256 proposalId = proposalCount++;
        Proposal storage proposal = proposals[proposalId];
        
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.description = description;
        proposal.startTime = block.timestamp + votingDelay;
        proposal.endTime = block.timestamp + votingDelay + votingPeriod;
        
        emit ProposalCreated(proposalId, msg.sender, description, proposal.startTime, proposal.endTime);
        
        return proposalId;
    }
    
    /**
     * @dev Cast a vote on a proposal
     * @param proposalId Proposal ID
     * @param support True for support, false for opposition
     */
    function castVote(uint256 proposalId, bool support) external notBlacklisted(msg.sender) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(block.timestamp >= proposal.startTime, "Voting not started");
        require(block.timestamp < proposal.endTime, "Voting ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        require(!proposal.canceled, "Proposal canceled");
        
        uint256 weight = balanceOf(msg.sender);
        require(weight > 0, "No voting power");
        
        proposal.hasVoted[msg.sender] = true;
        
        if (support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }
        
        emit VoteCast(msg.sender, proposalId, support, weight);
    }
    
    /**
     * @dev Execute a successful proposal
     * @param proposalId Proposal ID
     */
    function executeProposal(uint256 proposalId) external onlyOwner {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(block.timestamp >= proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(!proposal.canceled, "Proposal canceled");
        require(proposal.forVotes > proposal.againstVotes, "Proposal not passed");
        require(proposal.forVotes >= quorum, "Quorum not reached");
        
        proposal.executed = true;
        emit ProposalExecuted(proposalId);
    }
    
    /**
     * @dev Cancel a proposal (owner only)
     * @param proposalId Proposal ID
     */
    function cancelProposal(uint256 proposalId) external onlyOwner {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.id == proposalId, "Proposal does not exist");
        require(!proposal.executed, "Already executed");
        require(!proposal.canceled, "Already canceled");
        
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }
    
    /**
     * @dev Set minimum token requirement for proposal creation
     * @param newMinTokens New minimum token requirement
     */
    function setMinProposalTokens(uint256 newMinTokens) external onlyOwner {
        require(newMinTokens > 0, "Minimum tokens must be greater than 0");
        minProposalTokens = newMinTokens;
        emit MinProposalTokensUpdated(newMinTokens);
    }
    
    /**
     * @dev Initiate a cross-chain bridge request
     * @param targetChainId Target chain ID
     * @param amount Amount to bridge
     */
    function initiateBridge(uint256 targetChainId, uint256 amount) external payable notBlacklisted(msg.sender) nonReentrant {
        require(supportedChains[targetChainId], "Chain not supported");
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= maxBridgeAmount, "Amount exceeds bridge limit");
        //require(msg.value >= bridgeFee, "Insufficient bridge fee");
        // Calculate total required ETH (bridge fee)
        uint256 totalRequired = bridgeFee;
        require(msg.value >= totalRequired, "Insufficient bridge fee");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        uint256 requestId = bridgeRequestCount++;
        BridgeRequest storage request = bridgeRequests[requestId];
        
        request.from = msg.sender;
        request.amount = amount;
        request.targetChainId = targetChainId;
        request.timestamp = block.timestamp;
        request.requestHash = keccak256(abi.encodePacked(msg.sender, targetChainId, amount, block.timestamp));
        
        // Burn tokens
        _burn(msg.sender, amount);
        totalBurned += amount;
        
        // Collect bridge fee
        bridgeFeesCollected += msg.value;
        
        emit BridgeRequestInitiated(requestId, msg.sender, amount, targetChainId);
    }
    
    /**
     * @dev Process a bridge request (bridge operator only)
     * @param requestId Bridge request ID
     * @param to Recipient address
     * @param sourceChainId Source chain ID
     */
    function processBridge(uint256 requestId, address to, uint256 sourceChainId) external onlyBridgeOperator notBlacklisted(to) {
        BridgeRequest storage request = bridgeRequests[requestId];
        require(request.from != address(0), "Request does not exist");
        require(!request.processed, "Already processed");
        require(!request.canceled, "Request canceled");
        require(supportedChains[sourceChainId], "Source chain not supported");
        
        request.processed = true;
        
        // Mint tokens to recipient
        _mint(to, request.amount);
        totalMinted += request.amount;
        
        emit BridgeRequestProcessed(requestId, to, request.amount, sourceChainId);
    }
    
    /**
     * @dev Set bridge operator status
     * @param operator Address to set as operator
     * @param isOperator_ Operator status
     */
    function setBridgeOperator(address operator, bool isOperator_) external onlyOwner {
        bridgeOperators[operator] = isOperator_;
        emit BridgeOperatorUpdated(operator, isOperator_);
    }
    
    /**
     * @dev Set supported chain status
     * @param chainId Chain ID
     * @param isSupported Support status
     */
    function setSupportedChain(uint256 chainId, bool isSupported) external onlyOwner {
        supportedChains[chainId] = isSupported;
        emit SupportedChainUpdated(chainId, isSupported);
    }
    
    /**
     * @dev Update bridge fee
     * @param newFee New bridge fee
     */
    function updateBridgeFee(uint256 newFee) external onlyOwner {
        bridgeFee = newFee;
        emit BridgeFeeUpdated(newFee);
    }
    
    /**
     * @dev Update bridge limits
     * @param newMaxAmount New maximum bridge amount
     */
    function updateBridgeLimits(uint256 newMaxAmount) external onlyOwner {
        require(newMaxAmount > 0, "Max amount must be greater than 0");
        maxBridgeAmount = newMaxAmount;
        emit BridgeLimitsUpdated(newMaxAmount);
    }
    
    /**
     * @dev Withdraw collected bridge fees
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawBridgeFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Cannot withdraw to zero address");
        require(amount <= bridgeFeesCollected, "Insufficient fees");
        
        bridgeFeesCollected -= amount;
        payable(to).transfer(amount);
        
        emit BridgeFeesWithdrawn(to, amount);
    }
    
    /**
     * @dev Get proposal information
     * @param proposalId Proposal ID
     */
    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        string memory description,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 startTime,
        uint256 endTime,
        bool executed,
        bool canceled
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.description,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.startTime,
            proposal.endTime,
            proposal.executed,
            proposal.canceled
        );
    }
    
    /**
     * @dev Get vote information for a proposal
     * @param proposalId Proposal ID
     * @param voter Voter address
     */
    function getVoteInfo(uint256 proposalId, address voter) external view returns (bool hasVoted) {
        return proposals[proposalId].hasVoted[voter];
    }
    
    /**
     * @dev Get bridge request information
     * @param requestId Request ID
     */
    function getBridgeRequest(uint256 requestId) external view returns (
        address from,
        uint256 amount,
        uint256 targetChainId,
        uint256 timestamp,
        bytes32 requestHash,
        bool processed,
        bool canceled
    ) {
        BridgeRequest storage request = bridgeRequests[requestId];
        return (
            request.from,
            request.amount,
            request.targetChainId,
            request.timestamp,
            request.requestHash,
            request.processed,
            request.canceled
        );
    }
    
    /**
     * @dev Get bridge statistics
     */
    function getBridgeStats() external view returns (
        uint256 totalRequests,
        uint256 processedRequests,
        uint256 feesCollected,
        uint256 maxAmount
    ) {
        return (
            bridgeRequestCount,
            bridgeRequestCount, // Simplified for now
            bridgeFeesCollected,
            maxBridgeAmount
        );
    }
    
    /**
     * @dev Check if bridge request is processed
     * @param requestId Request ID
     */
    function isBridgeProcessed(uint256 requestId) external view returns (bool) {
        return bridgeRequests[requestId].processed;
    }
    
    /**
     * @dev Override _update to include blacklist and pause checks
     */
    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Pausable) {
        require(!isBlacklisted[from], "Sender is blacklisted");
        require(!isBlacklisted[to], "Recipient is blacklisted");
        super._update(from, to, value);
    }
    

}
