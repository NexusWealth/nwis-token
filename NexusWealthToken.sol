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
 * @notice ERC20 with governance, blacklist, and PRESALE PAUSE functionality.
 * @dev Enhanced with presale-specific pause that allows purchases but blocks transfers
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

    // === Blacklist Operators ===
    mapping(address => bool) public blacklistOperators;
    event BlacklistOperatorUpdated(address indexed operator, bool status);
    event AddressBlacklisted(address indexed user, bool status);

    // === Presale Pause Feature ===
    bool public presalePauseEnabled;
    address public presaleContract;
    mapping(address => bool) public presalePauseWhitelist;
    
    event PresalePauseEnabled();
    event PresalePauseDisabled();
    event PresaleContractUpdated(address indexed oldContract, address indexed newContract);
    event PresalePauseWhitelistUpdated(address indexed account, bool status);

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
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 eta;  // Execution time (for timelock)
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalCount;
    uint256 public constant MIN_EXECUTION_DELAY = 14 days;
    uint256 public constant MAX_EXECUTION_DELAY = 30 days;

    uint256 public proposalThreshold;
    uint256 public votingDelay;
    uint256 public votingPeriod;
    uint256 public quorumNumerator;
    uint256 public constant QUORUM_DENOMINATOR = 10_000;
    uint256 public constant MAX_BATCH_SIZE = 100;

    event ProposalCreated(uint256 indexed id, address indexed proposer, uint256 snapshotBlock, uint256 startBlock, uint256 endBlock, string description);
    event VoteCast(uint256 indexed id, address indexed voter, VoteType support, uint256 weight);
    event ProposalCanceled(uint256 indexed id);
    event ProposalQueued(uint256 indexed id, uint256 eta);
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

        proposalThreshold = 0;
        votingDelay = 0;
        votingPeriod = 45_000;
        quorumNumerator = 400;
        
        // Initialize presale pause as disabled
        presalePauseEnabled = false;
    }

    // ===== Admin setters =====
    function setBlacklistOperator(address operator, bool status) external onlyOwner {
        blacklistOperators[operator] = status;
        emit BlacklistOperatorUpdated(operator, status);
    }

    // ===== Presale Pause Functions =====
    /**
     * @notice Set the presale contract address
     * @param _presaleContract Address of the presale contract
     */
    function setPresaleContract(address _presaleContract) external onlyOwner {
        require(_presaleContract != address(0), "Zero address not allowed");
        address oldContract = presaleContract;
        presaleContract = _presaleContract;
        emit PresaleContractUpdated(oldContract, _presaleContract);
    }

    /**
     * @notice Enable presale pause mode - allows only presale purchases, blocks transfers
     */
    function enablePresalePause() external onlyOwner {
        require(presaleContract != address(0), "Presale contract not set");
        presalePauseEnabled = true;
        emit PresalePauseEnabled();
    }

    /**
     * @notice Disable presale pause mode - re-enables normal transfers
     */
    function disablePresalePause() external onlyOwner {
        presalePauseEnabled = false;
        emit PresalePauseDisabled();
    }

    /**
     * @notice Add or remove address from presale pause whitelist
     * @param account Address to whitelist/unwhitelist
     * @param status True to whitelist, false to remove
     */
    function setPresalePauseWhitelist(address account, bool status) external onlyOwner {
        require(account != address(0), "Cannot whitelist zero address");
        presalePauseWhitelist[account] = status;
        emit PresalePauseWhitelistUpdated(account, status);
    }

    /**
     * @notice Batch whitelist multiple addresses
     * @param accounts Array of addresses to whitelist
     * @param status True to whitelist all, false to remove all
     */
    function setPresalePauseWhitelistBatch(address[] calldata accounts, bool status) external onlyOwner {
        require(accounts.length > 0 && accounts.length <= MAX_BATCH_SIZE, "Invalid batch size");
        
        for (uint256 i = 0; i < accounts.length; i++) {
            require(accounts[i] != address(0), "Zero address in batch");
            presalePauseWhitelist[accounts[i]] = status;
            emit PresalePauseWhitelistUpdated(accounts[i], status);
        }
    }

    /**
     * @notice Check if presale pause is active
     */
    function isPresalePaused() external view returns (bool) {
        return presalePauseEnabled;
    }

    // ===== Blacklist management =====
    modifier onlyBlacklistAdmin() {
        require(msg.sender == owner() || blacklistOperators[msg.sender], "Not authorized");
        _;
    }

    function setBlacklistStatus(address user, bool status) external onlyBlacklistAdmin {
        require(user != address(0), "Cannot blacklist zero address");
        isBlacklisted[user] = status;
        emit AddressBlacklisted(user, status);
    }

    // ===== ERC20 controls =====
    function decimals() public view override returns (uint8) { return _customDecimals; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Mint new tokens (up to maxSupply)
     * @param to Address to receive minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Cannot mint to zero address");
        require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
        _mint(to, amount);
        totalMinted += amount;
    }

    /**
     * @notice Burn tokens (inherited from ERC20Burnable)
     * @dev Users can burn their own tokens, reduces total supply
     */
    function burn(uint256 amount) public override {
        super.burn(amount);
        totalBurned += amount;
    }

    /**
     * @notice Burn tokens from another account (requires allowance)
     * @param account Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address account, uint256 amount) public override {
        super.burnFrom(account, amount);
        totalBurned += amount;
    }

    // ===== Governance API =====
    function quorum(uint256 ) public view returns (uint256) {
        return (totalSupply() * quorumNumerator) / QUORUM_DENOMINATOR;
    }

    function setVotingParams(uint256 _threshold, uint256 _delay, uint256 _period, uint256 _quorumNumerator)
        external
        onlyOwner
    {
        require(_quorumNumerator >= 100 && _quorumNumerator <= QUORUM_DENOMINATOR, "Invalid quorum");
        require(_period >= 6_500 && _period <= 200_000, "Invalid period");
        require(_delay <= 50_000, "Delay too long");
        require(_threshold <= maxSupply / 100, "Threshold too high");
        
        proposalThreshold = _threshold;
        votingDelay = _delay;
        votingPeriod = _period;
        quorumNumerator = _quorumNumerator;
    }

    function createProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 id) {
        require(getPastVotes(msg.sender, block.number - 1) >= proposalThreshold, "threshold");
        require(targets.length == values.length && targets.length == calldatas.length, "length mismatch");
        require(targets.length > 0, "no actions");
        require(targets.length <= 10, "too many actions");
        
        // Prevent governance from transferring ownership
        bytes4 transferOwnershipSelector = bytes4(keccak256("transferOwnership(address)"));
        for (uint256 i = 0; i < calldatas.length; i++) {
            require(calldatas[i].length < 4 || bytes4(calldatas[i]) != transferOwnershipSelector, 
                    "governance cannot transfer ownership");
        }
        
        id = ++proposalCount;
        uint256 snap = block.number;
        uint256 start = snap + votingDelay;
        uint256 end = start + votingPeriod;
        
        Proposal storage p = proposals[id];
        p.proposer = msg.sender;
        p.description = description;
        p.snapshotBlock = snap;
        p.startBlock = start;
        p.endBlock = end;
        p.targets = targets;
        p.values = values;
        p.calldatas = calldatas;
        
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
        if (p.executed) return "Executed";
        if (block.number < p.startBlock) return "Pending";
        if (block.number <= p.endBlock) return "Active";
        uint256 turnout = p.forVotes + p.againstVotes + p.abstainVotes;
        if (turnout < quorum(p.snapshotBlock)) return "Defeated";
        if (p.forVotes <= p.againstVotes) return "Defeated";
        if (p.eta > 0 && block.timestamp < p.eta) return "Queued";
        if (p.eta > 0 && block.timestamp > p.eta + MAX_EXECUTION_DELAY) return "Expired";
        if (p.eta > 0) return "Ready";
        return "Succeeded";
    }

    function cancel(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.canceled && !p.executed, "finalized");
        require(msg.sender == p.proposer || msg.sender == owner(), "not auth");
        p.canceled = true;
        emit ProposalCanceled(id);
    }

    function queue(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.canceled && !p.executed, "finalized");
        require(p.eta == 0, "already queued");
        require(block.number > p.endBlock, "still active");
        uint256 turnout = p.forVotes + p.againstVotes + p.abstainVotes;
        require(turnout >= quorum(p.snapshotBlock), "no quorum");
        require(p.forVotes > p.againstVotes, "not passed");
        
        p.eta = block.timestamp + MIN_EXECUTION_DELAY;
        emit ProposalQueued(id, p.eta);
    }

    function execute(uint256 id) external payable nonReentrant {
        Proposal storage p = proposals[id];
        require(!p.canceled && !p.executed, "finalized");
        require(p.eta > 0, "not queued");
        require(block.timestamp >= p.eta, "timelock not met");
        require(block.timestamp <= p.eta + MAX_EXECUTION_DELAY, "execution expired");
        
        // Prevent governance from transferring ownership
        bytes4 transferOwnershipSelector = bytes4(keccak256("transferOwnership(address)"));
        for (uint256 i = 0; i < p.calldatas.length; i++) {
            require(p.calldatas[i].length < 4 || bytes4(p.calldatas[i]) != transferOwnershipSelector, 
                    "governance cannot transfer ownership");
        }
        
        p.executed = true;
        
        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool success, bytes memory returndata) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            require(success, string(abi.encodePacked("execution failed at action ", _toString(i), ": ", _getRevertMsg(returndata))));
        }
        
        emit ProposalExecuted(id);
    }
    
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    
    function _getRevertMsg(bytes memory returndata) internal pure returns (string memory) {
        if (returndata.length < 68) return "execution reverted";
        assembly {
            returndata := add(returndata, 0x04)
        }
        return abi.decode(returndata, (string));
    }
    
    function getActions(uint256 id) external view returns (
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas
    ) {
        Proposal storage p = proposals[id];
        return (p.targets, p.values, p.calldatas);
    }

    // ===== Required overrides =====
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        // Check blacklist first
        if (from != address(0)) require(!isBlacklisted[from], "Sender blacklisted");
        if (to != address(0)) require(!isBlacklisted[to], "Recipient blacklisted");
        
        // Check presale pause mode (only if not fully paused)
        if (presalePauseEnabled && !paused()) {
            // Allow minting (from == address(0)) and burning (to == address(0))
            if (from != address(0) && to != address(0)) {
                // Check if this is an allowed transfer during presale pause
                bool isPresaleTransfer = (from == presaleContract);
                bool isSenderWhitelisted = presalePauseWhitelist[from];
                bool isRecipientWhitelisted = presalePauseWhitelist[to];
                
                require(
                    isPresaleTransfer || isSenderWhitelisted || isRecipientWhitelisted,
                    "Transfers paused: presale only"
                );
            }
        }
        
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
