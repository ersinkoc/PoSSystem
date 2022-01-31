// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./SafeMath.sol";

contract PoSSystem {
    using SafeMath for uint256;
    mapping(address => mapping(address => uint256)) private _validatorSey;
    mapping(address => uint256) private _validatorIndex;
    mapping(address => mapping(uint256 => uint256))
        private _EpochStakesForValidator;
    mapping(uint256 => mapping(address => uint256))
        private _ValidatorStakesForEpoch;

    struct Epoch {
        uint256 epoch;
        uint256 totalRewards;
        uint256 totalSelfStakes;
        uint256 totalUserStakes;
        uint256 totalRewardScore;
    }

    // epoch -> ( validator_index -> self_stake )
    mapping(uint256 => mapping(uint256 => uint256))
        public selfstakeByValidatorAtEpoch;

    struct EpochValidator {
        address coinbase;
        uint256 selfStake;
    }

    struct Validator {
        address owner;
        address coinbase;
        uint256 commission;
        string name;
        uint256 selfStake;
        uint256 firstEpoch;
        uint256 finalEpoch;
        bool resigned;
        bool expired;
    }

    Validator[] private validatorList;

    struct Vote {
        address user;
        address validator;
        uint256 startEpoch;
        uint256 endEpoch;
        bool active;
        uint256 amount;
        VoteType voteType;
    }

    struct UserVotes {
        address user;
        Vote[] user_votes;
    }

    UserVotes[] private userVotes;

    struct ValidatorVotes {
        address validator;
        Vote[] user_votes;
    }

    ValidatorVotes[] private validatorVotes;

    mapping(address => address) CoinbaseOwners;

    struct User {
        address user;
        uint256 totalRewards;
    }

    User[] private userList;

    struct UserInfos {
        uint256 index;
        address user;
        uint256 totalRewards;
        uint256 lockedBalance;
        uint256 unlockedBalance;
    }

    /// User deposits

    struct Deposit {
        //address user;
        uint256 amount;
        uint256 epoch;
    }

    struct UserDeposit {
        address user;
        Deposit[] user_deposits;
    }

    UserDeposit[] internal userDeposits;

    ///

    mapping(uint256 => Epoch) public _epochList;

    mapping(address => uint256) private _userIndex;

    mapping(address => mapping(BalanceTypes => uint256)) private _userBalance;

    mapping(address => bool) private _blacklistedAccount;

    // Events

    event Deposited(address indexed user, uint256 amount, uint256 epoch);

    // Enums

    enum BalanceTypes {
        LOCKED,
        UNLOCKED
    }

    enum VoteType {
        SELFSTAKE,
        USERSTAKE
    }
    uint256 private _totalDeposits;

    uint256 public constant minimumSelfStake = 10000 * 10**18;
    uint256 private constant blockTime = 15;
    uint256 private constant EpochTime = (24 * 60 * 60) / blockTime;
    uint256 private constant VotingTime = (23 * 60 * 60) / blockTime;
    uint256 private constant epochFirstBlock = 100000;
    uint256 private constant maximumEpochForVotes = 15; // 15 epoch
    uint256 private constant maximumEpochForValidators = 30; // 30 epoch

    uint256 private fakeNextEpoch = 0;
    uint256 public initilazedLastEpoch = 0;

    struct ResignBalance {
        uint256 releaseEpoch;
        uint256 amount;
    }

    mapping(uint256 => ResignBalance) public ResignBalances;

    error NotEnoughBalance(uint256 minimum, uint256 balance);

    constructor() {
        userList.push(); // 0-empty
        userDeposits.push(); // 0-empty
        userVotes.push(); // 0-empty
        validatorList.push(); // 0-empty
        _setFakeNextEpoch(1);
        epochInit();
    }

    modifier onlyStakers() {
        require(_userIndex[msg.sender] > 0, "You are not staker!");
        _;
    }

    modifier CoinbaseOwner(address coinbase) {
        require(
            CoinbaseOwners[coinbase] == msg.sender,
            "You are not validator owner!"
        );
        _;
    }

    // TEST PURPOSE //////////////////////////////////////////////////////////////////////////////////////////////
    function putSomeMoney(address _who, uint256 _amount) public returns (bool) {
        return _depositMoney(_who, _amount);
    }

    // ////////////////////////////////////////////////////////////////////////////////////////////////////////////

    // / Deposit
    receive() external payable {
        require(msg.value > 0, "Ho ho ho!");

        // require(!_blacklistedAccount[msg.sender], "You are in the blacklist!");
        _depositMoney(msg.sender, msg.value);
    }

    // / deposit
    function _depositMoney(address _who, uint256 _amount)
        internal
        returns (bool)
    {
        uint256 epoch = _calculateNextEpoch();
        uint256 index = _userIndex[_who];

        if (index == 0) {
            index = _addStakeholder(_who);
        }

        userDeposits[index].user_deposits.push(Deposit(_amount, epoch));

        _totalDeposits = _totalDeposits.add(_amount);
        _userBalance[_who][BalanceTypes.UNLOCKED] = _userBalance[_who][
            BalanceTypes.UNLOCKED
        ].add(_amount);

        emit Deposited(_who, _amount, epoch);
        return true;
    }

    function getMyDeposits() public view returns (UserDeposit memory) {
        uint256 uIndex = _userIndex[msg.sender];
        require(uIndex != 0, "You are not stake holder");
        return userDeposits[uIndex];
    }

    function applyCandidate(
        address coinbase,
        uint256 commission,
        string memory name,
        uint256 selfStake
    ) public returns (uint256) {
        require(
            _validatorIndex[coinbase] == 0,
            "Coinbase is already in the list"
        );
        require(selfStake >= minimumSelfStake, "minimumSelfStake Problem");

        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= minimumSelfStake,
            "User Balance is not enough for minimumSelfStake"
        );

        // if (
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] < minimumSelfStake
        // ) {
        //     revert NotEnoughBalance(
        //         minimumSelfStake,
        //         _userBalance[msg.sender][BalanceTypes.UNLOCKED]
        //     );
        // }

        validatorList.push();
        uint256 vIndex = validatorList.length - 1;

        if (vIndex == 0) {
            revert("Aooo");
        }

        uint256 firstEpoch = _calculateNextEpoch();
        uint256 finalEpoch = firstEpoch + maximumEpochForValidators - 1;

        validatorList[vIndex] = Validator(
            msg.sender,
            coinbase,
            commission,
            name,
            selfStake,
            firstEpoch,
            finalEpoch,
            false,
            false
        );

        _validatorIndex[coinbase] = vIndex;
        CoinbaseOwners[coinbase] = msg.sender;

        _userBalance[msg.sender][BalanceTypes.LOCKED] = _userBalance[
            msg.sender
        ][BalanceTypes.LOCKED].add(selfStake);
        _userBalance[msg.sender][BalanceTypes.UNLOCKED] = _userBalance[
            msg.sender
        ][BalanceTypes.UNLOCKED].sub(selfStake);

        for (uint256 i = 0; i < maximumEpochForValidators; i = i + 1) {
            if (_epochList[firstEpoch + i].epoch == 0) {
                _epochInitalize(firstEpoch + i);
            }
            _epochList[firstEpoch + i].totalSelfStakes = _epochList[
                firstEpoch + i
            ].totalSelfStakes.add(selfStake);
            selfstakeByValidatorAtEpoch[firstEpoch + i][vIndex] = selfStake;
        }

        // setVote(
        //     coinbase,
        //     selfStake,
        //     maximumEpochForValidators,
        //     VoteType.SELFSTAKE
        // );

        return vIndex;
    }

    // Validator can extend itself candidate period
    function extendCandidate(
        address coinbase,
        uint256 newFinalEpoch,
        uint256 increaseSelfStake
    ) public CoinbaseOwner(coinbase) returns (bool) {
        uint256 vIndex = _getValidatorIndex(coinbase);

        require(!validatorList[vIndex].resigned, "You are resigned");
        require(!validatorList[vIndex].expired, "You are expired");

        // require(ResignBalances[vIndex].epoch == 0, "You are resigned");

        if (validatorList[vIndex].owner != msg.sender) {
            revert("You are not owner of that validator");
        }
        uint256 selfStake = validatorList[vIndex].selfStake;
        uint256 newSelfStake = selfStake;

        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
                increaseSelfStake,
            "You have to deposit for increase"
        );

        uint256 oldFinalEpoch = validatorList[vIndex].finalEpoch;
        uint256 nextEpoch = _calculateNextEpoch();

        require(
            oldFinalEpoch >= nextEpoch,
            "You can not extend that coinbase, it is expired"
        );

        if (newFinalEpoch - nextEpoch > maximumEpochForValidators) {
            newFinalEpoch = nextEpoch + maximumEpochForValidators - 1;
        }

        validatorList[vIndex].finalEpoch = newFinalEpoch;

        if (increaseSelfStake != 0) {
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] = _userBalance[
                msg.sender
            ][BalanceTypes.UNLOCKED].sub(increaseSelfStake);
            _userBalance[msg.sender][BalanceTypes.LOCKED] = _userBalance[
                msg.sender
            ][BalanceTypes.LOCKED].add(increaseSelfStake);
            newSelfStake = selfStake.add(increaseSelfStake);
            validatorList[vIndex].selfStake = newSelfStake;
        }

        for (
            uint256 epoch = nextEpoch;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            // if (_epochList[epoch].epoch == 0) {
            //     _epochInitalize(epoch);
            // }

            selfstakeByValidatorAtEpoch[epoch][vIndex] = newSelfStake;

            if (epoch <= oldFinalEpoch && increaseSelfStake > 0) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(increaseSelfStake);
            }

            if (epoch > oldFinalEpoch) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(newSelfStake);
            }
        }

        return true;
    }

    function resignCandidate(address coinbase, uint256 newFinalEpoch)
        public
        CoinbaseOwner(coinbase)
        returns (bool)
    {
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch
        require(
            newFinalEpoch < nextEpoch + 7,
            "You can not resign before next 7 epochs"
        );

        uint256 vIndex = _getValidatorIndex(coinbase);
        require(
            ResignBalances[vIndex].releaseEpoch == 0,
            "You already resigned"
        );

        uint256 oldFinalEpoch = validatorList[vIndex].finalEpoch;
        if (newFinalEpoch > oldFinalEpoch) {
            revert("You dont need to resign");
        }
        validatorList[vIndex].finalEpoch = newFinalEpoch;
        for (
            uint256 epoch = oldFinalEpoch + 1;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            delete selfstakeByValidatorAtEpoch[epoch][vIndex];
        }

        // Unbound
        ResignBalances[vIndex] = ResignBalance(
            newFinalEpoch.add(1),
            validatorList[vIndex].selfStake
        );

        validatorList[vIndex].resigned = true;

        return true;
    }

    function unlockSelfStake(address coinbase)
        public
        CoinbaseOwner(coinbase)
        returns (bool)
    {
        uint256 vIndex = _getValidatorIndex(coinbase);

        if (validatorList[vIndex].owner != msg.sender) {
            revert("You are not owner of that validator");
        }

        require(validatorList[vIndex].resigned, "You are not resigned");

        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        if (
            ResignBalances[vIndex].releaseEpoch != 0 &&
            ResignBalances[vIndex].releaseEpoch < nextEpoch &&
            _userBalance[msg.sender][BalanceTypes.LOCKED] > 0
        ) {
            uint256 lockedSelfStake = ResignBalances[vIndex].amount;
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] = _userBalance[
                msg.sender
            ][BalanceTypes.UNLOCKED].add(lockedSelfStake);
            _userBalance[msg.sender][BalanceTypes.LOCKED] = _userBalance[
                msg.sender
            ][BalanceTypes.LOCKED].sub(lockedSelfStake);
            delete ResignBalances[vIndex];
        }

        return true;
    }

    function getMyUnlockedBalance() public view returns (uint256) {
        require(_userIndex[msg.sender] > 0, "You are not stake holder");
        return _userBalance[msg.sender][BalanceTypes.UNLOCKED];
    }

    function getMyLockedBalance() public view returns (uint256) {
        require(_userIndex[msg.sender] > 0, "You are not stake holder");
        return _userBalance[msg.sender][BalanceTypes.LOCKED];
    }

    function _getValidatorIndex(address who) internal view returns (uint256) {
        return _validatorIndex[who];
    }

    function getValidatorByIndex(uint256 index)
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

    function addMeAsStackHolder() public returns (uint256) {
        uint256 r = _addStakeholder(msg.sender);
        return r;
    }

    // / New User Record
    function _addStakeholder(address _user) internal returns (uint256) {
        uint256 uIndex = _userIndex[_user];

        if (uIndex == 0) {
            userList.push();
            userDeposits.push();
            userVotes.push();

            uIndex = userList.length - 1;

            userList[uIndex] = User(_user, 0);
            userDeposits[uIndex].user = _user;
            userVotes[uIndex].user = _user;

            _userIndex[_user] = uIndex;

            _userBalance[_user][BalanceTypes.UNLOCKED] = 0;
            _userBalance[_user][BalanceTypes.LOCKED] = 0;
        }

        return uIndex;
    }

    function setVote(
        address validator_coinbase,
        uint256 amount,
        uint256 maximumEpoch,
        VoteType voteType
    ) public onlyStakers returns (bool) {
        require(_validatorIndex[validator_coinbase] != 0, "Wrong Validator??");
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );

        uint256 maxEpoch = maximumEpochForVotes;

        if (voteType == VoteType.SELFSTAKE) {
            maxEpoch = maximumEpochForValidators;
        }

        if (maximumEpoch == 0 || maximumEpoch > maxEpoch) {
            maximumEpoch = maxEpoch;
        }

        uint256 index = _userIndex[msg.sender];
        uint256 startEpoch = _calculateNextEpoch();
        uint256 endEpoch = startEpoch + maximumEpoch;
        userVotes[index].user_votes.push(
            Vote(
                msg.sender,
                validator_coinbase,
                startEpoch,
                endEpoch,
                true,
                amount,
                voteType
            )
        );

        for (uint256 i = startEpoch; i <= endEpoch; i = i + 1) {
            if (_epochList[i].epoch == 0) {
                _epochInitalize(i);
            }
            if (voteType == VoteType.SELFSTAKE) {
                _epochList[i].totalSelfStakes.add(amount);
            } else {
                _epochList[i].totalUserStakes.add(amount);
            }
        }

        _userBalance[msg.sender][BalanceTypes.LOCKED] = _userBalance[
            msg.sender
        ][BalanceTypes.LOCKED].add(amount);
        _userBalance[msg.sender][BalanceTypes.UNLOCKED] = _userBalance[
            msg.sender
        ][BalanceTypes.UNLOCKED].sub(amount);

        // _validatorSey[validator][msg.sender] = amount;

        return true;
    }

    function _setFakeNextEpoch(uint256 epoch) public returns (bool) {
        fakeNextEpoch = epoch;
        return true;
    }

    function _calculateNextEpoch() public view returns (uint256) {
        if (fakeNextEpoch != 0) {
            return fakeNextEpoch;
        }

        uint256 blockNumber = block.number - epochFirstBlock; // 125334
        uint256 checkBlockNumber = blockNumber % EpochTime; // 4374
        uint256 nextEpoch = ((blockNumber - checkBlockNumber) / EpochTime) + 1;

        // ((125334-4374)/5760)+1 = 22
        // 5520..5760
        if (checkBlockNumber >= VotingTime) {
            nextEpoch = nextEpoch + 1;
        }

        // 22 = 126720 to 132480
        return nextEpoch;
    }

    function getValidatorList(uint256 _page, uint256 _resultsPerPage)
        public
        view
        returns (uint256, Validator[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 Validator per Page");
        uint256 _vlIndex = _resultsPerPage * _page - _resultsPerPage + 1;
        Validator memory emptyValidatorInfo = Validator(
            address(0),
            address(0),
            0,
            "",
            0,
            0,
            0,
            false,
            false
        );

        if (validatorList.length == 1 || _vlIndex > validatorList.length) {
            Validator[] memory _emptyReturn = new Validator[](1);
            _emptyReturn[0] = emptyValidatorInfo;
            return (0, _emptyReturn);
        }

        Validator[] memory _vlReturn = new Validator[](_resultsPerPage);
        uint256 _returnCounter = 0;
        for (_vlIndex; _vlIndex < _resultsPerPage * _page; _vlIndex++) {
            if (_vlIndex < validatorList.length) {
                _vlReturn[_returnCounter] = validatorList[_vlIndex];
            } else {
                _vlReturn[_returnCounter] = emptyValidatorInfo;
            }
            _returnCounter++;
        }
        return (validatorList.length - 1, _vlReturn);
    }

    function getUserList(uint256 _page, uint256 _resultsPerPage)
        public
        view
        returns (uint256, UserInfos[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 User per Page");
        uint256 _ulIndex = _resultsPerPage * _page - _resultsPerPage + 1;

        UserInfos memory emptyUserInfo = UserInfos(0, address(0), 0, 0, 0);

        if (userList.length == 1 || _ulIndex > userList.length) {
            UserInfos[] memory _emptyReturn = new UserInfos[](1);
            _emptyReturn[0] = emptyUserInfo;
            return (0, _emptyReturn);
        }

        UserInfos[] memory _ulReturn = new UserInfos[](_resultsPerPage);
        uint256 _returnCounter = 0;
        for (_ulIndex; _ulIndex < _resultsPerPage * _page; _ulIndex++) {
            if (_ulIndex < userList.length) {
                _ulReturn[_returnCounter] = UserInfos(
                    _ulIndex,
                    userList[_ulIndex].user,
                    userList[_ulIndex].totalRewards,
                    _userBalance[userList[_ulIndex].user][BalanceTypes.LOCKED],
                    _userBalance[userList[_ulIndex].user][BalanceTypes.UNLOCKED]
                );
            } else {
                _ulReturn[_returnCounter] = emptyUserInfo;
            }
            _returnCounter++;
        }
        return (userList.length - 1, _ulReturn);
    }

    // / Epoch Initalize --- maximumEpochForValidators+7 epoch
    // / Anyone Call
    function epochInit() public returns (uint256, uint256) {
        uint256 beforeInitilazedLastEpoch = initilazedLastEpoch;
        uint256 nextEpoch = _calculateNextEpoch();
        if (
            initilazedLastEpoch == 0 ||
            ((initilazedLastEpoch - nextEpoch) <
                (maximumEpochForValidators + 7))
        ) {
            uint256 newInits = 0;
            if (initilazedLastEpoch == 0) {
                newInits = maximumEpochForValidators + 7;
            } else {
                newInits =
                    maximumEpochForValidators +
                    7 -
                    (initilazedLastEpoch - nextEpoch);
            }
            for (uint256 i = 0; i < newInits; i = i + 1) {
                initilazedLastEpoch = initilazedLastEpoch + 1;
                _epochInitalize(initilazedLastEpoch);
            }
        }
        return (beforeInitilazedLastEpoch, initilazedLastEpoch);
    }

    function _epochInitalize(uint256 _epoch) internal {
        if (_epochList[_epoch].epoch == 0) {
            _epochList[_epoch] = Epoch(_epoch, 0, 0, 0, 0);
            selfstakeByValidatorAtEpoch[_epoch][0] = 0;
        }
    }

    function getVote(address validator) public view returns (uint256) {
        return _validatorSey[validator][msg.sender];
    }

    function removeVote(address validator) public returns (bool) {
        delete _validatorSey[validator][msg.sender];
        return true;
    }
}
