// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

import {SafeMath} from "./SafeMath.sol";

contract ValidatorSet {
    using SafeMath for uint256;

    mapping(address => bool) public _validator;
    mapping(address => mapping(address => uint256)) public _validatorSey;
    mapping(address => uint256) public _validatorIndex;

    struct EpochInfo {
        uint256 epoch;
        uint256 startBlock;
        uint256 endBlock;
        uint256 totalUserStakes;
        uint256 totalRewards;
        uint256 totalValidatorSelfStakes;
    }

    struct Validator {
        address owner;
        address payout;
        address signer;
        uint256 commission;
        string name;
        uint256 selfStake;
    }

    struct Vote {
        address user;
        address validator;
        uint256 startEpoch;
        uint256 endEpoch;
        bool active;
        uint256 amount;
    }

    struct UserVotes {
        address user;
        Vote[] user_votes;
    }

    UserVotes[] public userVotes;
    Validator[] public validatorList;

    struct Stake {
        address user;
        uint256 amount;
        uint256 since;
        uint256 claimable;
    }

    struct UserStake {
        address user;
        Stake[] address_stakes;
    }

    UserStake[] internal userStakes;

    enum BalanceTypes {
        LOCKED,
        UNLOCKED
    }

    mapping(uint256 => EpochInfo) internal _epochList;
    mapping(address => uint256) internal _userIndex;
    mapping(address => uint256) internal _userVotesIndex;

    mapping(address => bool) internal _userActive;
    mapping(address => mapping(BalanceTypes => uint256)) internal _userBalance;

    event Staked(
        address indexed user,
        uint256 amount,
        uint256 index,
        uint256 timestamp
    );

    mapping(address => bool) private _blacklistedAccount;

    uint256 internal _totalStake;

    uint256 minimumSelfStake = 10000 * 10**18;
    uint256 blockTime = 15;
    uint256 EpochTime = (24 * 60 * 60) / blockTime;
    uint256 VotingTime = (23 * 60 * 60) / blockTime;
    uint256 epochFirstBlock = 100000;

    constructor() {
        userStakes.push(); // 0-empty
        userVotes.push();
    }

    modifier onlyStakers() {
        require(_userActive[msg.sender], "You are not staker!");
        _;
    }

    function BecomeAValidator(
        address payout,
        address signer,
        uint256 commission,
        string memory name,
        uint256 selfStake
    ) public returns (uint256) {
        require(!_validator[signer], "Signer already in validator list");
        require(selfStake >= minimumSelfStake, "minimumSelfStake Problem");
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= minimumSelfStake,
            "User Balance is not enough for minimumSelfStake"
        );

        validatorList.push();
        uint256 vIndex = validatorList.length - 1;
        validatorList[vIndex] = Validator(
            msg.sender,
            payout,
            signer,
            commission,
            name,
            selfStake
        );
        _validatorIndex[signer] = vIndex;
        _validator[signer] = true;

        return vIndex;
    }

    function getValidator(uint256 index)
        public
        view
        returns (Validator memory)
    {
        return validatorList[index];
    }

    function getValidatorIndex(address validator)
        public
        view
        returns (uint256)
    {
        return _validatorIndex[validator];
    }

    /// Deposit Coin
    receive() external payable {
        require(!_blacklistedAccount[msg.sender], "You are in the blacklist!");
        _stake(msg.value);
    }

    /// Staking
    function _stake(uint256 _amount) internal {
        require(_amount > 0, "Cannot stake!");

        uint256 timestamp = block.timestamp;
        uint256 index = _userIndex[msg.sender];

        if (index == 0) {
            index = _addStakeholder(msg.sender);
        }

        userStakes[index].address_stakes.push(
            Stake(msg.sender, _amount, timestamp, 0)
        );

        _totalStake.add(_amount);
        _userBalance[msg.sender][BalanceTypes.UNLOCKED].add(_amount);

        emit Staked(msg.sender, _amount, index, timestamp);
    }

    /// New User Record
    function _addStakeholder(address staker) internal returns (uint256) {
        userStakes.push();
        uint256 userIndex = userStakes.length - 1;
        userStakes[userIndex].user = staker;
        userVotes[userIndex].user = staker;
        _userIndex[staker] = userIndex;
        _userActive[staker] = true;
        return userIndex;
    }

    function setVote(
        address validator,
        uint256 amount,
        uint256 epoch
    ) public onlyStakers returns (bool) {
        require(_validator[validator], "Wrong Validator??");
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );

        if (epoch == 0) epoch = 365;
        uint256 index = _userIndex[msg.sender];
        uint256 startEpoch = _getNextEpoch();
        uint256 endEpoch = startEpoch + epoch;
        userVotes[index].user_votes.push(
            Vote(msg.sender, validator, startEpoch, endEpoch, true, amount)
        );

        for (uint256 i = startEpoch; i <= endEpoch; i++) {
            if (_epochList[i].epoch == 0) {
                _EpochInit(i);
            }
            _epochList[i].totalUserStakes += amount;
        }

        _userBalance[msg.sender][BalanceTypes.LOCKED].add(amount);
        _userBalance[msg.sender][BalanceTypes.UNLOCKED].sub(amount);

        //_validatorSey[validator][msg.sender] = amount;

        return true;
    }

    function _getNextEpoch() internal view returns (uint256) {
        uint256 blockNumber = block.number - epochFirstBlock; // 125334
        uint256 checkBlockNumber = blockNumber % EpochTime; //4374
        uint256 nextEpoch = ((blockNumber - checkBlockNumber) / EpochTime) + 1; // ((125334-4374)/5760)+1 = 22

        // 5520..5760
        if (checkBlockNumber >= VotingTime) {
            nextEpoch++;
        }
        // 22 = 126720 to 132480
        return nextEpoch;
    }

    function _EpochInit(uint256 _epoch) internal returns (bool) {
        if (_epochList[_epoch].epoch == 0) {
            _epochList[_epoch] = EpochInfo(
                _epoch,
                epochFirstBlock + (_epoch * EpochTime),
                epochFirstBlock + ((_epoch + 1) * EpochTime) - 1,
                0,
                0,
                0
            );
        }
        return true;
    }

    function getVote(address validator) public view returns (uint256) {
        return _validatorSey[validator][msg.sender];
    }

    function removeVote(address validator) public returns (bool) {
        delete _validatorSey[validator][msg.sender];
        return true;
    }
}
