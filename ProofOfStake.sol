// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./SafeMath.sol";
import {Data} from "./Data.sol";

contract ProofOfStake {
    using SafeMath for uint256;
    mapping(address => mapping(address => uint256)) private _validatorSey;
    mapping(uint256 => Data.Epoch) public _epochList;

    // epoch -> ( validator_index -> self_stake )
    mapping(uint256 => mapping(uint256 => uint256)) public selfStakesForEpoch;
    // epoch -> ( validator_index -> user_vote)
    mapping(uint256 => mapping(uint256 => uint256)) public userVotesForEpoch;

    Data.User[] private _userList;
    mapping(address => uint256) private _userIndex;
    mapping(address => mapping(Data.BalanceTypes => uint256))
        private _userBalance;

    Data.Validator[] private _validatorList;
    mapping(address => uint256) private _validatorIndex;
    mapping(address => address) CoinbaseOwners;
    mapping(uint256 => Data.ResignBalance) public ResignBalances;

    Data.UserVotes[] private userVotes;
    Data.ValidatorVotes[] private validatorVotes;
    Data.UserDeposit[] private userDeposits;

    /** Events */
    event Deposited(address indexed user, uint256 amount, uint256 epoch);

    mapping(address => bool) private _blacklistedAccount;

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

    error NotEnoughBalance(uint256 minimum, uint256 balance);

    constructor() {
        _userList.push(); // 0-empty
        userDeposits.push(); // 0-empty
        userVotes.push(); // 0-empty
        _validatorList.push(); // 0-empty
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

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */
    function putSomeMoney(address _who, uint256 _amount) public returns (bool) {
        return _depositMoney(_who, _amount);
    }

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */

    /** Deposit */
    receive() external payable {
        require(msg.value > 0, "Ho ho ho!");

        // require(!_blacklistedAccount[msg.sender], "You are in the blacklist!");
        _depositMoney(msg.sender, msg.value);
    }

    /** Deposit Money */
    function _depositMoney(address _who, uint256 _amount)
        internal
        returns (bool)
    {
        uint256 epoch = _calculateNextEpoch();
        uint256 index = _userIndex[_who];

        if (index == 0) {
            index = _addStakeholder(_who);
        }

        userDeposits[index].user_deposits.push(Data.Deposit(_amount, epoch));

        _totalDeposits = _totalDeposits.add(_amount);
        _userBalance[_who][Data.BalanceTypes.UNLOCKED] = _userBalance[_who][
            Data.BalanceTypes.UNLOCKED
        ].add(_amount);

        emit Deposited(_who, _amount, epoch);
        return true;
    }

    function getMyDeposits() public view returns (Data.UserDeposit memory) {
        uint256 uIndex = _userIndex[msg.sender];
        require(uIndex != 0, "You are not stake holder");
        return userDeposits[uIndex];
    }

    function registerValidator(
        address coinbase,
        uint256 commission,
        string memory name,
        uint256 selfStake
    ) public returns (uint256) {
        require(
            _validatorIndex[coinbase] == 0,
            "This validator address is already registered!"
        );
        require(
            selfStake >= minimumSelfStake,
            "Self-Stake is not an acceptable amount"
        );

        require(
            _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] >=
                minimumSelfStake,
            "You do not have enough unlocked balances for Self-Stake."
        );

        // if (
        //     _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] < minimumSelfStake
        // ) {
        //     revert NotEnoughBalance(
        //         minimumSelfStake,
        //         _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED]
        //     );
        // }

        _validatorList.push();
        uint256 vIndex = _validatorList.length - 1;

        if (vIndex == 0) {
            revert("Aooo");
        }

        uint256 firstEpoch = _calculateNextEpoch();
        uint256 finalEpoch = firstEpoch + maximumEpochForValidators - 1;

        _validatorList[vIndex] = Data.Validator(
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

        _userBalance[msg.sender][Data.BalanceTypes.LOCKED] = _userBalance[
            msg.sender
        ][Data.BalanceTypes.LOCKED].add(selfStake);
        _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] = _userBalance[
            msg.sender
        ][Data.BalanceTypes.UNLOCKED].sub(selfStake);

        for (uint256 i = 0; i < maximumEpochForValidators; i = i + 1) {
            if (_epochList[firstEpoch + i].epoch == 0) {
                _epochInitalize(firstEpoch + i);
            }
            _epochList[firstEpoch + i].totalSelfStakes = _epochList[
                firstEpoch + i
            ].totalSelfStakes.add(selfStake);
            selfStakesForEpoch[firstEpoch + i][vIndex] = selfStake;
        }

        // setVote(
        //     coinbase,
        //     selfStake,
        //     maximumEpochForValidators,
        //     VotingType.SELFSTAKE
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

        require(!_validatorList[vIndex].resigned, "You are resigned");
        require(!_validatorList[vIndex].expired, "You are expired");

        // require(ResignBalances[vIndex].epoch == 0, "You are resigned");

        if (_validatorList[vIndex].owner != msg.sender) {
            revert("You are not owner of that validator");
        }
        uint256 selfStake = _validatorList[vIndex].selfStake;
        uint256 newSelfStake = selfStake;

        require(
            _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] >=
                increaseSelfStake,
            "You have to deposit for increase"
        );

        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;
        uint256 nextEpoch = _calculateNextEpoch();

        require(
            oldFinalEpoch >= nextEpoch,
            "You can not extend that coinbase, it is expired"
        );

        if (newFinalEpoch - nextEpoch > maximumEpochForValidators) {
            newFinalEpoch = nextEpoch + maximumEpochForValidators - 1;
        }

        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        if (increaseSelfStake != 0) {
            _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] = _userBalance[
                msg.sender
            ][Data.BalanceTypes.UNLOCKED].sub(increaseSelfStake);
            _userBalance[msg.sender][Data.BalanceTypes.LOCKED] = _userBalance[
                msg.sender
            ][Data.BalanceTypes.LOCKED].add(increaseSelfStake);
            newSelfStake = selfStake.add(increaseSelfStake);
            _validatorList[vIndex].selfStake = newSelfStake;
        }

        for (
            uint256 epoch = nextEpoch;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            // if (_epochList[epoch].epoch == 0) {
            //     _epochInitalize(epoch);
            // }

            selfStakesForEpoch[epoch][vIndex] = newSelfStake;

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

        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;
        if (newFinalEpoch > oldFinalEpoch) {
            revert("You dont need to resign");
        }
        _validatorList[vIndex].finalEpoch = newFinalEpoch;
        for (
            uint256 epoch = oldFinalEpoch + 1;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            delete selfStakesForEpoch[epoch][vIndex];
        }

        // Unbound
        ResignBalances[vIndex] = Data.ResignBalance(
            newFinalEpoch.add(1),
            _validatorList[vIndex].selfStake
        );

        _validatorList[vIndex].resigned = true;

        return true;
    }

    function unlockSelfStake(address coinbase)
        public
        CoinbaseOwner(coinbase)
        returns (bool)
    {
        uint256 vIndex = _getValidatorIndex(coinbase);

        // if (_validatorList[vIndex].owner != msg.sender) {
        //     revert("You are not owner of that validator");
        // }

        require(_validatorList[vIndex].resigned, "You are not resigned");

        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        if (
            ResignBalances[vIndex].releaseEpoch != 0 &&
            ResignBalances[vIndex].releaseEpoch < nextEpoch &&
            _userBalance[msg.sender][Data.BalanceTypes.LOCKED] > 0
        ) {
            uint256 lockedSelfStake = ResignBalances[vIndex].amount;
            _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] = _userBalance[
                msg.sender
            ][Data.BalanceTypes.UNLOCKED].add(lockedSelfStake);
            _userBalance[msg.sender][Data.BalanceTypes.LOCKED] = _userBalance[
                msg.sender
            ][Data.BalanceTypes.LOCKED].sub(lockedSelfStake);
            delete ResignBalances[vIndex];
        }

        return true;
    }

    function getMyUnlockedBalance() public view returns (uint256) {
        require(_userIndex[msg.sender] > 0, "You are not stake holder");
        return _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED];
    }

    function getMyLockedBalance() public view returns (uint256) {
        require(_userIndex[msg.sender] > 0, "You are not stake holder");
        return _userBalance[msg.sender][Data.BalanceTypes.LOCKED];
    }

    function _getValidatorIndex(address who) internal view returns (uint256) {
        return _validatorIndex[who];
    }

    function getValidatorByIndex(uint256 index)
        public
        view
        returns (Data.Validator memory)
    {
        return _validatorList[index];
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
            _userList.push();
            userDeposits.push();
            userVotes.push();

            uIndex = _userList.length - 1;

            _userList[uIndex] = Data.User(_user, 0);
            userDeposits[uIndex].user = _user;
            userVotes[uIndex].user = _user;

            _userIndex[_user] = uIndex;

            _userBalance[_user][Data.BalanceTypes.UNLOCKED] = 0;
            _userBalance[_user][Data.BalanceTypes.LOCKED] = 0;
        }

        return uIndex;
    }

    function setVote(
        address coinbase,
        uint256 amount,
        uint256 maximumEpoch,
        Data.VotingType votingType
    ) public onlyStakers returns (bool) {
        require(_validatorIndex[coinbase] != 0, "Wrong Validator??");
        require(
            _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );

        uint256 maxEpoch = maximumEpochForVotes;

        // if (VotingType == VotingType.SELFSTAKE) {
        //     maxEpoch = maximumEpochForValidators;
        // }

        if (maximumEpoch == 0 || maximumEpoch > maxEpoch) {
            maximumEpoch = maxEpoch;
        }

        uint256 vIndex = _validatorIndex[coinbase];
        Data.Validator memory v = _validatorList[vIndex];
        uint256 nextEpoch = _calculateNextEpoch();
        if (nextEpoch + maximumEpoch - 1 > v.finalEpoch) {
            maximumEpoch = v.finalEpoch - nextEpoch;
        }

        uint256 index = _userIndex[msg.sender];
        uint256 startEpoch = nextEpoch;
        uint256 endEpoch = startEpoch + maximumEpoch;

        // struct Vote {
        //     address user;
        //     address validator;
        //     uint256 startEpoch;
        //     uint256 endEpoch;
        //     bool active;
        //     uint256 amount;
        //     VotingType VotingType;
        // }

        userVotes[index].user_votes.push(
            Data.Vote(
                msg.sender,
                coinbase,
                startEpoch,
                endEpoch,
                true,
                amount,
                votingType
            )
        );

        for (uint256 epoch = startEpoch; epoch <= endEpoch; epoch++) {
            if (_epochList[epoch].epoch == 0) {
                _epochInitalize(epoch);
            }
            // if (VotingType == VotingType.SELFSTAKE) {
            //     _epochList[i].totalSelfStakes.add(amount);
            // } else {
            _epochList[epoch].totalUserStakes = _epochList[epoch]
                .totalUserStakes
                .add(amount);
            // }

            userVotesForEpoch[epoch][vIndex] = userVotesForEpoch[epoch][vIndex]
                .add(amount);
        }

        _userBalance[msg.sender][Data.BalanceTypes.LOCKED] = _userBalance[
            msg.sender
        ][Data.BalanceTypes.LOCKED].add(amount);
        _userBalance[msg.sender][Data.BalanceTypes.UNLOCKED] = _userBalance[
            msg.sender
        ][Data.BalanceTypes.UNLOCKED].sub(amount);

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
        returns (uint256, Data.Validator[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 Validators per Page");
        uint256 _vlIndex = _resultsPerPage * _page - _resultsPerPage + 1;
        Data.Validator memory emptyValidatorInfo = Data.Validator(
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

        if (_validatorList.length == 1 || _vlIndex > _validatorList.length) {
            Data.Validator[] memory _emptyReturn = new Data.Validator[](1);
            _emptyReturn[0] = emptyValidatorInfo;
            return (0, _emptyReturn);
        }

        Data.Validator[] memory _vlReturn = new Data.Validator[](
            _resultsPerPage
        );
        uint256 _returnCounter = 0;
        for (_vlIndex; _vlIndex < _resultsPerPage * _page; _vlIndex++) {
            if (_vlIndex < _validatorList.length) {
                _vlReturn[_returnCounter] = _validatorList[_vlIndex];
            } else {
                _vlReturn[_returnCounter] = emptyValidatorInfo;
            }
            _returnCounter++;
        }
        return (_validatorList.length - 1, _vlReturn);
    }

    function getUserList(uint256 _page, uint256 _resultsPerPage)
        public
        view
        returns (uint256, Data.SummaryOfUser[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 Users per Page");
        uint256 _ulIndex = _resultsPerPage * _page - _resultsPerPage + 1;

        Data.SummaryOfUser memory emptyUserInfo = Data.SummaryOfUser(
            0,
            address(0),
            0,
            0,
            0
        );

        if (_userList.length == 1 || _ulIndex > _userList.length) {
            Data.SummaryOfUser[] memory _emptyReturn = new Data.SummaryOfUser[](
                1
            );
            _emptyReturn[0] = emptyUserInfo;
            return (0, _emptyReturn);
        }

        Data.SummaryOfUser[] memory _ulReturn = new Data.SummaryOfUser[](
            _resultsPerPage
        );
        uint256 _returnCounter = 0;
        for (_ulIndex; _ulIndex < _resultsPerPage * _page; _ulIndex++) {
            if (_ulIndex < _userList.length) {
                _ulReturn[_returnCounter] = Data.SummaryOfUser(
                    _ulIndex,
                    _userList[_ulIndex].user,
                    _userList[_ulIndex].totalRewards,
                    _userBalance[_userList[_ulIndex].user][
                        Data.BalanceTypes.LOCKED
                    ],
                    _userBalance[_userList[_ulIndex].user][
                        Data.BalanceTypes.UNLOCKED
                    ]
                );
            } else {
                _ulReturn[_returnCounter] = emptyUserInfo;
            }
            _returnCounter++;
        }
        return (_userList.length - 1, _ulReturn);
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
            _epochList[_epoch] = Data.Epoch(_epoch, 0, 0, 0, 0);
            selfStakesForEpoch[_epoch][0] = 0;
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
