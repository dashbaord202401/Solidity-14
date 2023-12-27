// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Staking is Ownable {
    uint256 roundNumber = 10**12;
    /**
     *      Contract's states
     */
    // Stake token contract
    IERC20 public token;
    // Reward token contract
    IERC20 public rewardToken;
    // Pool of reward token
    address public rewardPool;
    // Pausable flag
    bool public pausable;
    // Claim flag
    bool public claimable;
    // Start time of the stake campaign
    uint256 public startBlockNumber;
    // End time of the stake campaign
    uint256 public endBlockNumber;
    // Total staked token in contract
    uint256 public totalStaked;
    // Lock time when user claim token
    uint256 public lockBlockNumber;
    // Reward per block
    uint256 public rewardPerBlock;

    // Reward token per stake token
    uint256 public publicK; 
    uint256 public lastblockUpdate;

    // User stake records: userAddress => StakeRecords
    mapping(address => StakeRecord) public userStakeRecords;
    // Lock unstack token: userAddress => endBlockNumberLock
    mapping(address => uint256) public userLockUnstake;

    /**
     *      Using struct
     */
    // Stored the record of staking token
    struct StakeRecord {
        uint256 amount;         // Amount of user staked amount
        uint256 blockNumber;    // Latest block number that user interact
        uint256 unclaimAmount;  // Unclaim amount reward token
        uint256 userK;
    }

    /**
     *      Events
     */
    event Stake(
        uint256 amount,
        address account,
        uint256 blockNumber,
        uint256 totalStaked,
        uint256 userK
    );
    event Claim(
        address userAddress,
        uint256 amount, 
        uint256 blockNumber,
        uint256 publicK
    );
    event Unstake(
        uint256 amount,
        address userAddress,
        uint256 totalStaked,
        uint256 publicK
    );

    constructor(
        address _stakeToken,            // Address of stake token
        address _rewardToken,           // Address of reward token
        address _rewardPool,            // Address of reward pool
        uint256 _startBlockNumber,      // In number of block. Ex: 1 block = 12s, 72h = 21600
        address _owner,                 // Address of owner
        uint256 _lockBlockNumber        // In number of block. Ex: 1 block = 12s, 72h = 21600
    ) Ownable(_owner) {
        require(_stakeToken != address(0), "Address zero not allowed");
        require(_rewardPool != address(0), "Address zero not allowed");
        require(_owner != address(0), "Address zero not allowed");

        token = IERC20(_stakeToken);
        rewardToken = IERC20(_rewardToken);
        rewardPool = _rewardPool;
        startBlockNumber = _startBlockNumber;
        endBlockNumber = _startBlockNumber + 151200;
        lockBlockNumber = _lockBlockNumber;

        transferOwnership(_owner);
        rewardPerBlock = uint256(12600000 * 10 ** 18)/ uint256(151200);
        pausable = false;
        publicK = 0;
        lastblockUpdate = startBlockNumber;
        claimable = true;
    }

    /**
     * 
     *  Modifier check contract is paused, campaign is start or end
     */
    modifier availableToAction() {
        require(pausable == false, "Not available to action now");
        require(startBlockNumber <= block.number , "Campaign does not start yet");
        require(endBlockNumber >= block.number, "Campaign already ended");
        _;
    }

    /**
     * Set pause/unpause for contract
     * @param _pausable pause status 
     */
    function setPausable(bool _pausable) external onlyOwner {
        pausable = _pausable;
    }

    /**
     * Set claimable/unclaimable for contract
     * @param _claimable pause status 
     */
    function setClaimable(bool _claimable) external onlyOwner {
        claimable = _claimable;
    }

    /**
     * Set start block number for campaign
     * @param _startBlockNumber Epoch timestamp 
     */
    function setStartBlockNumber(uint256 _startBlockNumber) external onlyOwner {
        startBlockNumber = _startBlockNumber;
    }

    /**
     * Set end block number for campaign
     * @param _endBlockNumber Epoch timestamp 
     */
    function setEndBlockNumber(uint256 _endBlockNumber) external onlyOwner {
        require(endBlockNumber > startBlockNumber, "Must be higher than start block number");
        endBlockNumber = _endBlockNumber;
    }

    /**
     * Set reward pool
     * @param _rewardPool address of reward pool
     */
    function setRewardPool(address _rewardPool) external onlyOwner {
        require(_rewardPool != address(0), "Address zero not allowed");
        rewardPool = _rewardPool;
    }

    /**
     *  Get amount of reward token in pool
     */
    function getRewardAmount () external view returns(uint256) {
        return rewardToken.balanceOf(rewardPool);
    }

    /**
     * Stake token in pool
     * @param _amount amount of stake token will be staked in pool
     */
    function stake(uint256 _amount) external availableToAction {
        require(
            token.balanceOf(msg.sender) >= _amount,
            "User need to hold enough token to stake"
        );
        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "Transfer token to stake contract failed"
        );

        calculatePublicK();
        StakeRecord memory record = userStakeRecords[msg.sender];
        if (record.amount == 0 ) {
            userStakeRecords[msg.sender] = StakeRecord({
                amount : _amount,
                userK : publicK,
                unclaimAmount : 0,
                blockNumber : block.number
            });
        } else {
            userStakeRecords[msg.sender].unclaimAmount = calculateUnclaimAmount(record);
            userStakeRecords[msg.sender].userK = publicK;
            userStakeRecords[msg.sender].amount += _amount;
            userStakeRecords[msg.sender].blockNumber = block.number;
        }

        // Add user staked amount
        totalStaked += _amount;
        emit Stake(
            _amount,
            msg.sender,
            block.number,
            totalStaked,
            record.userK
        );
    }

    function claim() external {
        require(userStakeRecords[msg.sender].amount > 0, "User hasn't staked any token");
        require(pausable == false, "Not available to action now");
        require(claimable, "User can't claim right now");

        calculatePublicK(); 

        StakeRecord memory record = userStakeRecords[msg.sender];
        uint256 totalClaim = record.unclaimAmount + calculateUnclaimAmount(record);
        
        // Transfer reward tokens to user
        require(totalClaim != 0, "Zero claim reward!!");
        require(rewardToken.transferFrom(rewardPool, msg.sender, totalClaim / roundNumber), "Pool not found");
        
        userStakeRecords[msg.sender].userK = publicK;
        userStakeRecords[msg.sender].unclaimAmount = 0;
        userStakeRecords[msg.sender].blockNumber = block.number;

        userLockUnstake[msg.sender] = block.number + lockBlockNumber;
        emit Claim(msg.sender, totalClaim, block.number, publicK);
    }

    /**
     * Unstake token in pool
     */
    function unstake() external {
        require(pausable == false, "Not available to action now");
        require(userLockUnstake[msg.sender] < block.number, "Staked token is locked");
        require(userStakeRecords[msg.sender].amount > 0, "User hasn't staked any token");
        calculatePublicK(); 
        uint256 _stackTokenAmount = userStakeRecords[msg.sender].amount;
        delete userStakeRecords[msg.sender];

        totalStaked -= _stackTokenAmount;
        token.transfer(msg.sender, _stackTokenAmount);
        emit Unstake(
            _stackTokenAmount,
            msg.sender,
            totalStaked,
            publicK
        );
    }

    function getUserReward(address _account) public view returns(uint256) {
        StakeRecord memory record = userStakeRecords[_account];
        if (record.amount == 0) {
            return 0;
        }
        
        uint256 nextBlock = block.number > endBlockNumber ? endBlockNumber : block.number;
        uint256 _publicK = publicK + (uint256(rewardPerBlock * roundNumber) / uint256(totalStaked)) * (nextBlock - lastblockUpdate);

        return uint256(record.amount * (_publicK - record.userK) + record.unclaimAmount) / roundNumber;
    }
    
    /**
     * Get user total stake token
     * @param _account user address
     */
    function getUserStakedAmount(address _account) external view returns (uint256) {
        return userStakeRecords[_account].amount;
    }


    // // Using in emergency case
    // function withdrawEmergency () external onlyOwner{
    //     token.transfer(msg.sender, token.balanceOf(address(this)));
    // }

    
    function calculatePublicK () internal {
        uint256 nextBlock = block.number > endBlockNumber ? endBlockNumber : block.number;
        if (lastblockUpdate != nextBlock && nextBlock <= endBlockNumber) {
            if (totalStaked != 0) {
                publicK += (uint256(rewardPerBlock * roundNumber) / uint256(totalStaked)) * (nextBlock - lastblockUpdate);
            }
            lastblockUpdate = nextBlock;
        }
    }

    function calculateUnclaimAmount (StakeRecord memory record) internal view returns(uint256) {
        return (publicK - record.userK) * record.amount;
    }

}
