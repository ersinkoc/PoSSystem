// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeMath} from "./SafeMath.sol";
import "./Data.sol";

contract ProofOfStake {
    using SafeMath for uint256;

    //mapping(address => mapping(address => uint256)) private _validatorSey;

    mapping(uint256 => Epoch) public _epochList;

    // epoch -> ( validator_index -> self_stake )
    mapping(uint256 => mapping(uint256 => uint256)) public selfStakesForEpoch;
    // epoch -> ( validator_index -> user_vote)
    mapping(uint256 => mapping(uint256 => uint256)) public userVotesForEpoch;

    User[] private _userList;
    mapping(address => uint256) private _userIndex;
    mapping(address => mapping(BalanceTypes => uint256)) private _userBalance;

    Validator[] private _validatorList;
    mapping(address => uint256) private _validatorIndex;
    mapping(address => address) CoinbaseOwners;
    mapping(uint256 => ResignBalance) public ResignBalances;

    UserVotes[] private userVotes;
    ValidatorVotes[] private validatorVotes;
    UserDeposit[] private userDeposits;

    /** Events */
    event Deposited(address indexed user, uint256 amount, uint256 epoch);

    mapping(address => bool) private _blacklistedAccount;

    uint256 private _totalDeposits;

    uint256 public constant _MINIMIMSELFSTAKE = 10000 * 10**18;
    uint256 private constant _BLOCKTIME = 15;
    uint256 private constant _EPOCHTIME = (24 * 60 * 60) / _BLOCKTIME;
    uint256 private constant _VOTINGTIME = (23 * 60 * 60) / _BLOCKTIME;
    uint256 private constant _EPOCHFIRSTBLOCK = 100000;
    uint256 private constant _MAXIMUMEPOCHFORVOTES = 15; // 15 epoch
    uint256 private constant _MAXIMUMEPOCHFORVALIDATORS = 30; // 30 epoch

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

    modifier PassworRequired(string memory _password) {
        bytes32 passCode = 0xb2876fa49f910e660fe95d6546d1c6c86c78af46f85672173ad5ab78d8143d9d;
        require(
            getHash({_text: "password", _anotherText: _password}) == passCode,
            "Password is not correct!"
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

        userDeposits[index].user_deposits.push(Deposit(_amount, epoch));

        _totalDeposits = _totalDeposits.add(_amount);

        // _userBalance[_who][BalanceTypes.UNLOCKED] = _userBalance[_who][
        //     BalanceTypes.UNLOCKED
        // ].add(_amount);

        _changeBalance(_who, BalanceTypes.UNLOCKED, BalanceChange.ADD, _amount);

        emit Deposited(_who, _amount, epoch);
        return true;
    }

    function getMyDeposits() public view returns (UserDeposit memory) {
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
            selfStake >= _MINIMIMSELFSTAKE,
            "Self-Stake is not an acceptable amount"
        );

        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
                _MINIMIMSELFSTAKE,
            "You do not have enough unlocked balances for Self-Stake."
        );

        // if (
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] < _MINIMIMSELFSTAKE
        // ) {
        //     revert NotEnoughBalance(
        //         _MINIMIMSELFSTAKE,
        //         _userBalance[msg.sender][BalanceTypes.UNLOCKED]
        //     );
        // }

        _validatorList.push();
        uint256 vIndex = _validatorList.length - 1;

        if (vIndex == 0) {
            revert("Aooo");
        }

        uint256 firstEpoch = _calculateNextEpoch();
        uint256 finalEpoch = firstEpoch + _MAXIMUMEPOCHFORVALIDATORS - 1;

        _validatorList[vIndex] = Validator({
            owner: msg.sender,
            coinbase: coinbase,
            commission: commission,
            name: name,
            selfStake: selfStake,
            firstEpoch: firstEpoch,
            finalEpoch: finalEpoch,
            resigned: false,
            expired: false
        });

        _validatorIndex[coinbase] = vIndex;
        CoinbaseOwners[coinbase] = msg.sender;

        _changeBalance(
            msg.sender,
            BalanceTypes.LOCKED,
            BalanceChange.ADD,
            selfStake
        );

        _changeBalance(
            msg.sender,
            BalanceTypes.UNLOCKED,
            BalanceChange.SUB,
            selfStake
        );

        for (uint256 i = 0; i < _MAXIMUMEPOCHFORVALIDATORS; i = i + 1) {
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
        //     _MAXIMUMEPOCHFORVALIDATORS,
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
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
                increaseSelfStake,
            "You have to deposit for increase"
        );

        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;
        uint256 nextEpoch = _calculateNextEpoch();

        require(
            oldFinalEpoch >= nextEpoch,
            "You can not extend that coinbase, it is expired"
        );

        if (newFinalEpoch - nextEpoch > _MAXIMUMEPOCHFORVALIDATORS) {
            newFinalEpoch = nextEpoch + _MAXIMUMEPOCHFORVALIDATORS - 1;
        }

        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        if (increaseSelfStake != 0) {
            _changeBalance(
                msg.sender,
                BalanceTypes.LOCKED,
                BalanceChange.ADD,
                increaseSelfStake
            );

            _changeBalance(
                msg.sender,
                BalanceTypes.UNLOCKED,
                BalanceChange.SUB,
                increaseSelfStake
            );

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
        ResignBalances[vIndex] = ResignBalance(
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
            _userBalance[msg.sender][BalanceTypes.LOCKED] > 0
        ) {
            uint256 lockedSelfStake = ResignBalances[vIndex].amount;

            _changeBalance(
                msg.sender,
                BalanceTypes.UNLOCKED,
                BalanceChange.ADD,
                lockedSelfStake
            );

            _changeBalance(
                msg.sender,
                BalanceTypes.LOCKED,
                BalanceChange.SUB,
                lockedSelfStake
            );

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

            _userList[uIndex] = User({user: _user, totalRewards: 0});
            userDeposits[uIndex].user = _user;
            userVotes[uIndex].user = _user;

            _userIndex[_user] = uIndex;

            _userBalance[_user][BalanceTypes.UNLOCKED] = 0;
            _userBalance[_user][BalanceTypes.LOCKED] = 0;
        }

        return uIndex;
    }

    function setVote(
        address coinbase,
        uint256 amount,
        uint256 maximumEpoch,
        VotingType votingType
    ) public onlyStakers returns (bool) {
        require(_validatorIndex[coinbase] != 0, "Wrong Validator??");
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );

        uint256 maxEpoch = _MAXIMUMEPOCHFORVOTES;

        // if (VotingType == VotingType.SELFSTAKE) {
        //     maxEpoch = _MAXIMUMEPOCHFORVALIDATORS;
        // }

        if (maximumEpoch == 0 || maximumEpoch > maxEpoch) {
            maximumEpoch = maxEpoch;
        }

        uint256 vIndex = _validatorIndex[coinbase];
        Validator memory v = _validatorList[vIndex];
        uint256 nextEpoch = _calculateNextEpoch();
        if (nextEpoch + maximumEpoch - 1 > v.finalEpoch) {
            maximumEpoch = v.finalEpoch - nextEpoch;
        }

        uint256 index = _userIndex[msg.sender];
        uint256 startEpoch = nextEpoch;
        uint256 endEpoch = startEpoch + maximumEpoch;

        userVotes[index].user_votes.push(
            Vote({
                user: msg.sender,
                validator: coinbase,
                startEpoch: startEpoch,
                endEpoch: endEpoch,
                active: true,
                amount: amount,
                votingType: votingType
            })
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

        _changeBalance(
            msg.sender,
            BalanceTypes.LOCKED,
            BalanceChange.ADD,
            amount
        );
        _changeBalance(
            msg.sender,
            BalanceTypes.UNLOCKED,
            BalanceChange.SUB,
            amount
        );

        // _validatorSey[validator][msg.sender] = amount;

        return true;
    }

    function _changeBalance(
        address who,
        BalanceTypes balanceType,
        BalanceChange change,
        uint256 amount
    ) internal returns (bool) {
        if (change == BalanceChange.ADD) {
            _userBalance[who][balanceType] = _userBalance[who][balanceType].add(
                amount
            );
        }

        if (change == BalanceChange.SUB) {
            {
                _userBalance[who][balanceType] = _userBalance[who][balanceType]
                    .sub(amount);
            }
        }
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

        uint256 blockNumber = block.number - _EPOCHFIRSTBLOCK; // 125334
        uint256 checkBlockNumber = blockNumber % _EPOCHTIME; // 4374
        uint256 nextEpoch = ((blockNumber - checkBlockNumber) / _EPOCHTIME) + 1;

        // ((125334-4374)/5760)+1 = 22
        // 5520..5760
        if (checkBlockNumber >= _VOTINGTIME) {
            nextEpoch = nextEpoch + 1;
        }

        // 22 = 126720 to 132480
        return nextEpoch;
    }

    function getValidatorList(
        uint256 _page,
        uint256 _resultsPerPage,
        string memory _password
    )
        public
        view
        PassworRequired(_password)
        returns (uint256, Validator[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 Validators per Page");
        uint256 _vlIndex = _resultsPerPage * _page - _resultsPerPage + 1;

        Validator memory emptyValidatorInfo = Validator({
            owner: address(0),
            coinbase: address(0),
            commission: 0,
            name: "",
            selfStake: 0,
            firstEpoch: 0,
            finalEpoch: 0,
            resigned: false,
            expired: false
        });

        if (_validatorList.length == 1 || _vlIndex > _validatorList.length) {
            Validator[] memory _emptyReturn = new Validator[](1);
            _emptyReturn[0] = emptyValidatorInfo;
            return (0, _emptyReturn);
        }

        Validator[] memory _vlReturn = new Validator[](_resultsPerPage);

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

    function getUserList(
        uint256 _page,
        uint256 _resultsPerPage,
        string memory _password
    )
        public
        view
        PassworRequired(_password)
        returns (uint256, SummaryOfUser[] memory)
    {
        require(_resultsPerPage <= 20, "Maximum 20 Users per Page");
        uint256 _ulIndex = _resultsPerPage * _page - _resultsPerPage + 1;

        SummaryOfUser memory emptyUserInfo = SummaryOfUser({
            index: 0,
            user: address(0),
            totalRewards: 0,
            lockedBalance: 0,
            unlockedBalance: 0
        });

        if (_userList.length == 1 || _ulIndex > _userList.length) {
            SummaryOfUser[] memory _emptyReturn = new SummaryOfUser[](1);
            _emptyReturn[0] = emptyUserInfo;
            return (0, _emptyReturn);
        }

        SummaryOfUser[] memory _ulReturn = new SummaryOfUser[](_resultsPerPage);
        uint256 _returnCounter = 0;
        for (_ulIndex; _ulIndex < _resultsPerPage * _page; _ulIndex++) {
            if (_ulIndex < _userList.length) {
                _ulReturn[_returnCounter] = SummaryOfUser({
                    index: _ulIndex,
                    user: _userList[_ulIndex].user,
                    totalRewards: _userList[_ulIndex].totalRewards,
                    lockedBalance: _userBalance[_userList[_ulIndex].user][
                        BalanceTypes.LOCKED
                    ],
                    unlockedBalance: _userBalance[_userList[_ulIndex].user][
                        BalanceTypes.UNLOCKED
                    ]
                });
            } else {
                _ulReturn[_returnCounter] = emptyUserInfo;
            }
            _returnCounter++;
        }
        return (_userList.length - 1, _ulReturn);
    }

    // / Epoch Initalize --- _MAXIMUMEPOCHFORVALIDATORS+7 epoch
    // / Anyone Call
    function epochInit() public returns (uint256, uint256) {
        uint256 beforeInitilazedLastEpoch = initilazedLastEpoch;
        uint256 nextEpoch = _calculateNextEpoch();
        if (
            initilazedLastEpoch == 0 ||
            ((initilazedLastEpoch - nextEpoch) <
                (_MAXIMUMEPOCHFORVALIDATORS + 7))
        ) {
            uint256 newInits = 0;
            if (initilazedLastEpoch == 0) {
                newInits = _MAXIMUMEPOCHFORVALIDATORS + 7;
            } else {
                newInits =
                    _MAXIMUMEPOCHFORVALIDATORS +
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
            _epochList[_epoch] = Epoch({
                epoch: _epoch,
                totalRewards: 0,
                totalSelfStakes: 0,
                totalUserStakes: 0,
                totalRewardScore: 0
            });
            selfStakesForEpoch[_epoch][0] = 0;
        }
    }

    // function getVote(address validator) public view returns (uint256) {
    //     return _validatorSey[validator][msg.sender];
    // }

    // function removeVote(address validator) public returns (bool) {
    //     delete _validatorSey[validator][msg.sender];
    //     return true;
    // }

    /** ------------------------------------------------------------------------------------------- */
    function getHash(string memory _text, string memory _anotherText)
        public
        pure
        returns (bytes32)
    {
        // encodePacked(AAA, BBB) -> AAABBB
        // encodePacked(AA, ABBB) -> AAABBB
        return keccak256(abi.encodePacked(_text, _anotherText));
    }
    /** ------------------------------------------------------------------------------------------- */
}
