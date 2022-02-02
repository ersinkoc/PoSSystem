// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7;

import {SafeMath} from "./SafeMath.sol";
import "./Data.sol";

contract ProofOfStake {
    using SafeMath for uint256;

    mapping(uint256 => Epoch) public _epochList;

    // epoch -> ( validator_index -> self_stake )
    mapping(uint256 => mapping(uint256 => uint256)) public selfStakesForEpoch;

    // epoch -> ( validator_index -> user_vote)
    mapping(uint256 => mapping(uint256 => uint256)) public userVotesForEpoch;

    // epoch -> ( validator_index -> user_vote + self-stake)
    mapping(uint256 => mapping(uint256 => uint256)) public votingPowerForEpoch;

    // epoch -> ( siralama ->  validator index )
    /**
        Epoch   No      vIndex
        1 =>    1   =   1
                2   =   15
                3   =   8
                ..  =   ..
                37  =   ..
    */
    mapping(uint256 => mapping(uint256 => uint256)) public selectedValidators;

    User[] private _userList;
    mapping(address => uint256) private _userIndex;
    mapping(address => mapping(BalanceTypes => uint256)) private _userBalance;

    Validator[] private _validatorList;
    mapping(address => uint256) private _validatorIndex;
    mapping(address => address) private coinbaseOwners;
    mapping(uint256 => ResignBalance) public resignBalances;

    UserVotes[] private userVotes;
    ValidatorVotes[] private validatorVotes;
    UserDeposit[] private userDeposits;

    /** Events */
    event Deposited(address indexed user, uint256 amount, uint256 epoch);
    event DotEnoughBalance(uint256 minimum, uint256 balance);
    event FailedEvent(string failText);

    mapping(address => bool) private _blacklistedAccount;

    uint256 private _totalDeposits;
    uint256[] private emptyVotes;
    uint256 private constant _MAX = 19;
    uint256 private constant _MULTIPLE = 1_000_000_000_000;
    uint256 public constant _MINIMIMSELFSTAKE = 10000 * 10**18;
    uint256 private constant _BLOCKTIME = 15;
    uint256 private constant _EPOCHTIME = (24 * 60 * 60) / _BLOCKTIME;
    uint256 private constant _VOTINGTIME = (23 * 60 * 60) / _BLOCKTIME;
    uint256 private constant _EPOCHFIRSTBLOCK = 100000;
    uint256 private constant _MAXIMUMEPOCHFORVOTES = 7; // 7 epoch
    uint256 private constant _MAXIMUMEPOCHFORVALIDATORS = 30; // 30 epoch
    uint256 private constant _VOTINGPERSELFSTAKE = 100;

    uint256 private fakeNextEpoch = 0;
    uint256 public initilazedLastEpoch = 0;

    constructor() {
        _userList.push(); // 0-empty
        userDeposits.push(); // 0-empty
        userVotes.push(); // 0-empty
        _validatorList.push(); // 0-empty
        _setFakeNextEpoch(1);
        epochInit();
    }

    modifier NotInBlacklist() {
        require(!_blacklistedAccount[msg.sender], "You are in the blacklist");
        _;
    }

    // Sadece oxo deposit yatırmış ve kaydı olanlar işlem yapabilir
    modifier OnlyStakers() {
        require(_userIndex[msg.sender] > 0, "You are not staker!");
        _;
    }

    // coinbase adresinin sahibi işlem yapabilir
    modifier CoinbaseOwnerCheck(address coinbase) {
        require(
            coinbaseOwners[coinbase] == msg.sender,
            "You are not validator owner!"
        );
        _;
    }

    // Parola gerektiren fonksiyonlar için :) Deneysel
    modifier PassworRequired(string memory _password) {
        bytes32 passCode = 0xb2876fa49f910e660fe95d6546d1c6c86c78af46f85672173ad5ab78d8143d9d;
        require(
            getHash({_text: "password", _anotherText: _password}) == passCode,
            "Password is not correct!"
        );
        _;
    }

    // kilitsiz bakiyesi fonksiyon için yetersiz ise işleme devam etme
    modifier UnlockedBalanceCheck(uint256 amount) {
        require(
            _userBalance[msg.sender][BalanceTypes.UNLOCKED] >= amount,
            "Your unlocked balance is not enough"
        );
        _;
    }

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */
    // Deneme süresinde kullanıcılara deposito yapmasalar bile bakiye eklemek için
    function putSomeMoney(address _who, uint256 _amount) public returns (bool) {
        return _depositMoney(_who, _amount);
    }

    /** ////////////////////////////////////////////////////////////////////////////////////////////////////////// */

    /** Deposit */
    // OXO yatırma
    receive() external payable {
        require(msg.value > 0, "Ho ho ho!");

        // require(!_blacklistedAccount[msg.sender], "You are in the blacklist!");
        _depositMoney(msg.sender, msg.value);
    }

    /** Deposit Money */
    // OXO yattığında (veya sahtesinde) kullanıcıya bakiye ekleme
    function _depositMoney(address _who, uint256 _amount)
        internal
        returns (bool)
    {
        // Sonraki dönem bilgisi
        uint256 epoch = _calculateNextEpoch();

        // Kullanıcı index bilgisini getir
        uint256 index = _userIndex[_who];

        // Eğer kayıtlı kullanıcı değilse kaydet
        if (index == 0) {
            index = _addStakeholder(_who);
        }

        // Kullanıcı para yatırma işlemlerine kaydı ekle
        userDeposits[index].user_deposits.push(Deposit(_amount, epoch));

        // Sisteme yatırılan paraları artır
        _totalDeposits = _totalDeposits.add(_amount);

        // _userBalance[_who][BalanceTypes.UNLOCKED] = _userBalance[_who][
        //     BalanceTypes.UNLOCKED
        // ].add(_amount);

        // Kullanıcı kilitsiz para miktarını artır
        _changeBalance(_who, BalanceTypes.UNLOCKED, BalanceChange.ADD, _amount);

        // Deposited eventini tetikle
        emit Deposited(_who, _amount, epoch);
        return true;
    }

    // Kullanıcının yatırdığı para kaydını görür
    function getUserDeposits(address who)
        public
        view
        returns (UserDeposit memory)
    {
        // kullanıcı index bilgisini getir
        uint256 uIndex = _userIndex[who];
        // Kullanıcı kayıtlı değilse işlemi durdur
        require(uIndex != 0, "You are not stake holder");
        // Kullanıcı deposits dizisini dön
        return userDeposits[uIndex];
    }

    // Validatör adaylık kaydı (coinbase = node imzalama adresi, commission = oy verenlerin gelirinden alacağı pay ..)
    function registerValidator(
        address coinbase,
        uint256 commission,
        string memory name,
        uint256 selfStake
    ) public UnlockedBalanceCheck(selfStake) returns (uint256) {
        // Daha önce kayıtlı bir coinbase mi diye kontrol
        require(
            _validatorIndex[coinbase] == 0,
            "This validator address is already registered!"
        );

        // SelfStake nin mininmum selfstake ve üstü olmasını kontrol
        require(
            selfStake >= _MINIMIMSELFSTAKE,
            "Self-Stake is not an acceptable amount"
        );

        // // Kullanıcının selfstake yapacak kadar kilitsiz bakiyesi var mı?
        // require(
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
        //         _MINIMIMSELFSTAKE,
        //     "You do not have enough unlocked balances for Self-Stake."
        // );

        // if (
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] < _MINIMIMSELFSTAKE
        // ) {
        //     revert NotEnoughBalance(
        //         _MINIMIMSELFSTAKE,
        //         _userBalance[msg.sender][BalanceTypes.UNLOCKED]
        //     );
        // }

        // Validator listesine 1 kayıt ekle
        _validatorList.push();

        // Son eklenen kaydın index bilgisini al
        uint256 vIndex = _validatorList.length - 1;

        // Bir sonraki dönemi getir
        uint256 firstEpoch = _calculateNextEpoch();

        // Adaylık bitiş tarihini hesapla
        uint256 finalEpoch = firstEpoch + _MAXIMUMEPOCHFORVALIDATORS - 1;

        // Validator kaydını index numarasına göre kaydet
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

        // index verisini coinbase adresi ile erişilebilir şekilde kaydet
        _validatorIndex[coinbase] = vIndex;

        // Sahiplik verisini kaydet
        coinbaseOwners[coinbase] = msg.sender;

        // selfstake miktarını kilitle
        _lockMyBalance(selfStake);

        // Adaylık süresi için dönem bilgilerini güncelle
        for (uint256 i = 0; i < _MAXIMUMEPOCHFORVALIDATORS; i = i + 1) {
            // Dönem başlık bilgisi hiç yoksa dönem bilgisi üret
            if (_epochList[firstEpoch + i].epoch == 0) {
                _epochInitalize(firstEpoch + i);
            }

            // Dönem üst bilgisindeki toplam selfstake miktarını artır
            _epochList[firstEpoch + i].totalSelfStakes = _epochList[
                firstEpoch + i
            ].totalSelfStakes.add(selfStake);

            // Dönem-> (ValidatorIndex->SelfStake) bilgisini kaydet
            selfStakesForEpoch[firstEpoch + i][vIndex] = selfStake;
            votingPowerForEpoch[firstEpoch + i][vIndex] = selfStake;

            // Toplist düzeltme
            registerVotes(vIndex, firstEpoch + i);
        }

        // setVote(
        //     coinbase,
        //     selfStake,
        //     _MAXIMUMEPOCHFORVALIDATORS,
        //     VotingType.SELFSTAKE
        // );

        return vIndex;
    }

    // Validatör adaylık bitiş süresi değiştirebilir, aynı zamanda selfstake miktarı da artırılabilir
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

        // Eğer bu validator kaydı geri çekilmişse hata ver
        require(!_validatorList[vIndex].resigned, "You are resigned");

        // Eğer bu validator kaydı geçmişte kalmışsa hata ver
        require(!_validatorList[vIndex].expired, "You are expired");

        // Mevcut selfstake miktarını al
        uint256 selfStake = _validatorList[vIndex].selfStake;

        uint256 newSelfStake = selfStake;

        // // Eğer selfstake miktarı artırılacaksa bunun için yeterli kilitsiz bakiye var mı diye kontrol et
        // require(
        //     _userBalance[msg.sender][BalanceTypes.UNLOCKED] >=
        //         increaseSelfStake,
        //     "You have to deposit for increase"
        // );

        // Validatörün kayıtlı adaylık bitiş dönemini al
        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;

        // Gelecek dönem bilgisini al
        uint256 nextEpoch = _calculateNextEpoch();

        // Eğer validatör adaylık bitiş süresini geçirmişse hata ver
        require(
            oldFinalEpoch >= nextEpoch,
            "You can not extend that coinbase, it is expired"
        );

        // Uzatılacak dönem maximum aday olunabilir dönem sayısını geçiyorsa bunu olabilecek en geç dönem ile değiştir
        if (newFinalEpoch - nextEpoch > _MAXIMUMEPOCHFORVALIDATORS) {
            newFinalEpoch = nextEpoch + _MAXIMUMEPOCHFORVALIDATORS - 1;
        }

        // Validatör bilgisinde yeni adaylık bitiş dönemini kaydet
        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        // Eğer selfstake miktarı artırılıyorsa kilitsiz bakiyeden ilgili miktarı kilitli bakiyeye ekle
        if (increaseSelfStake != 0) {
            _lockMyBalance(increaseSelfStake);

            // Yeni selfstake miktarını eksiyle topla ve validatör kaydını değiştir
            newSelfStake = selfStake.add(increaseSelfStake);
            _validatorList[vIndex].selfStake = newSelfStake;
        }

        // Gelecek dönem ve adaylık biteceği yeni dönem arasında döngüye gir
        for (
            uint256 epoch = nextEpoch;
            epoch <= newFinalEpoch;
            epoch = epoch + 1
        ) {
            // if (_epochList[epoch].epoch == 0) {
            //     _epochInitalize(epoch);
            // }

            // Validatörün ilgili dönemdeki selfstake miktarını kaydet (eskisini güncele veya yeni ekle)
            selfStakesForEpoch[epoch][vIndex] = newSelfStake;

            // Zaten aday olduğu dönenmlerde totalSelfStakes e artırılan rakamını ilave et
            if (epoch <= oldFinalEpoch && increaseSelfStake > 0) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(increaseSelfStake);

                votingPowerForEpoch[epoch][vIndex] =
                    votingPowerForEpoch[epoch][vIndex] +
                    increaseSelfStake;
            }

            // Daha önceden aday olmadığı dönemler için toplam selfstake miktarını kaydet
            if (epoch > oldFinalEpoch) {
                _epochList[epoch].totalSelfStakes = _epochList[epoch]
                    .totalSelfStakes
                    .add(newSelfStake);

                votingPowerForEpoch[epoch][vIndex] = newSelfStake;
            }
        }

        return true;
    }

    // Validatörlüğe newFinalEpoch döneminde veda ediyor
    function resignCandidate(address coinbase, uint256 newFinalEpoch)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Sonraki dönem bilgisi
        uint256 nextEpoch = _calculateNextEpoch();

        // Sonraki 7 dönem geçtiğinde ayrılabilir. Daha erken ayrılamaz.
        require(
            newFinalEpoch >= nextEpoch + 7,
            "You can not resign before next 7 epochs"
        );

        // Validator sırasını Getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // Zaten ayrılmış :)
        require(
            resignBalances[vIndex].releaseEpoch == 0,
            "You already resigned"
        );

        //  Validatörün zaten kayıtlı son adaylık bitiş dönemini oku
        uint256 oldFinalEpoch = _validatorList[vIndex].finalEpoch;

        // adaylık bitiş döneminden daha sonraki bir dönem ayrılmak istiyorsa (salaksa)
        if (newFinalEpoch > oldFinalEpoch) {
            revert("You dont need to resign");
        }

        // Validatorün adaylık bitiş dönemini değiştir
        _validatorList[vIndex].finalEpoch = newFinalEpoch;

        // Yeni bitiş döneminden bir dönem sonra eski bitiş dönemine kadar selfstake kayıtlarını sil/çıkar
        for (
            uint256 epoch = oldFinalEpoch + 1;
            epoch <= newFinalEpoch;
            epoch++
        ) {
            // selfstake kaydını al
            uint256 selfStake = selfStakesForEpoch[epoch][vIndex];
            // dönem bilgisinden totalSelfStakes i azalt
            _epochList[epoch].totalSelfStakes = _epochList[epoch]
                .totalSelfStakes
                .sub(selfStake);

            //votingPowerForEpoch[epoch][vIndex] = votingPowerForEpoch[epoch][vIndex].sub(selfStake);

            // selfstake ve votingpower kaydını sil
            delete selfStakesForEpoch[epoch][vIndex];
            delete votingPowerForEpoch[epoch][vIndex];
        }

        // yeni adaylık bitiş döneminden 1 dönem sonra sonra parasını alsın kaydı
        resignBalances[vIndex] = ResignBalance(
            newFinalEpoch.add(1),
            _validatorList[vIndex].selfStake
        );

        // Validator bilgisi resigned olarak işaretle
        _validatorList[vIndex].resigned = true;

        return true;
    }

    // Adaylıktan çekilmiş olan Validatör daha önceden kaydedilen hedef dönem geldiğinde kilitli bakiyesindeki parayı kilitsiz bakiyeye aktarabilir
    function unlockSelfStakeAfterResigned(address coinbase)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Validatör index bilgisini getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // if (_validatorList[vIndex].owner != msg.sender) {
        //     revert("You are not owner of that validator");
        // }

        // Bu validatör adaylıktan mı çekilmiş?
        require(_validatorList[vIndex].resigned, "You are not resigned");

        // Bir sonraki dönem bilgisini getir
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        // Eğer ilgili kayıt varsa ve hedef serbest bırakma zamanı gelecek dönemden önce ise ve kilitli bakiyesi de varsa :)
        if (
            resignBalances[vIndex].releaseEpoch != 0 &&
            resignBalances[vIndex].releaseEpoch < nextEpoch &&
            _userBalance[msg.sender][BalanceTypes.LOCKED] > 0
        ) {
            // adaylıktan çekilirken ileride çözülmesi için kaydedilen bakiye miktarını al ve kilitli bakiyeden çıkarıp kilitsiz bakiyeye aktar
            uint256 lockedSelfStake = resignBalances[vIndex].amount;

            // kilitli rakamı kilitsiz bakiyeye aktar
            _unLockMyBalance(lockedSelfStake);

            // bu adaylıktan çekilmeye ait self-stake serbest bırakma kaydını sil
            delete resignBalances[vIndex];
        }

        return true;
    }

    // Adaylık dönemi bitmiş, kendisi adaylıktan çekilmemiş validatör için kilitli bakiyesini almasını sağlar (7 dönem sonra)
    function unlockSelfStakeAfterExpired(address coinbase)
        public
        CoinbaseOwnerCheck(coinbase)
        returns (bool)
    {
        // Validatör index bilgisini getir
        uint256 vIndex = _getValidatorIndex(coinbase);

        // Bu validatör bu şekilde kilitli bakyesini  geri almış mı?
        require(
            !_validatorList[vIndex].expired,
            "You already take your locked selfstake"
        );

        // Bir sonraki dönem bilgisini getir
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        // Adaylık bitiş tarihi gelecek dönem veya sonrasını gösteriyorsa expired olmamıştır
        if (_validatorList[vIndex].finalEpoch >= nextEpoch) {
            revert("You are not expired");
        }

        // Eğer validator adaylık süresi bitiminden 7 gün geçmemişse hata dön
        if (_validatorList[vIndex].finalEpoch + 7 < nextEpoch) {
            revert("You have to wait 7 epoch after expired");
        }

        // İmkansız ama kullanıcı kilitli bakiyesi ile bu validatör kaydı için kilitlediği selfstakeden azsa hata dön
        if (
            _userBalance[msg.sender][BalanceTypes.LOCKED] <
            _validatorList[vIndex].selfStake
        ) {
            revert("Houston! We have a problem");
        }

        // validatör expired kaydının true olarak değiştir
        _validatorList[vIndex].expired = true;

        // kilitli bakiyedeki validatörün son selfstake miktarını kilitsiz bakiyeye taşı
        _unLockMyBalance(_validatorList[vIndex].selfStake);

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

    // Validator kayıtlı ise index bilgisini getir (0-kayıtsız)
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

    // index ile validator adayı bilgisini getirir
    function getValidatorByIndex(uint256 index)
        public
        view
        returns (Validator memory)
    {
        return _validatorList[index];
    }

    /// TEST PURPOSE
    function addMeAsStackHolder() public returns (uint256) {
        uint256 r = _addStakeholder(msg.sender);
        return r;
    }

    ///

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
        uint256 maximumEpoch
    ) public OnlyStakers UnlockedBalanceCheck(amount) returns (bool) {
        uint256 vIndex = _validatorIndex[coinbase];
        // Validator var mı kontrolü
        require(vIndex != 0, "Validator is not available");

        // Validator bilgisi
        Validator memory v = _validatorList[vIndex];

        // Validator resigned veya expired olmamalı
        require(!v.expired, "Expired Validator");
        require(!v.resigned, "Resigned Validator");

        uint256 nextEpoch = _calculateNextEpoch();

        uint256 votingPower = amount;

        uint256 maxVotingPower = (selfStakesForEpoch[nextEpoch][vIndex] *
            _VOTINGPERSELFSTAKE) - userVotesForEpoch[nextEpoch][vIndex];

        if (amount > maxVotingPower) votingPower = maxVotingPower;

        if (maximumEpoch == 0 || maximumEpoch > _MAXIMUMEPOCHFORVOTES) {
            maximumEpoch = _MAXIMUMEPOCHFORVOTES;
        }

        if (nextEpoch - 1 + maximumEpoch > v.finalEpoch) {
            maximumEpoch = v.finalEpoch - nextEpoch;
        }

        uint256 index = _userIndex[msg.sender];
        uint256 endEpoch = nextEpoch - 1 + maximumEpoch;

        userVotes[index].user_votes.push(
            Vote({
                user: msg.sender,
                validator: coinbase,
                startEpoch: nextEpoch,
                endEpoch: endEpoch,
                active: true,
                amount: votingPower
            })
        );

        for (uint256 epoch = nextEpoch; epoch <= endEpoch; epoch++) {
            _epochList[epoch].totalUserStakes = _epochList[epoch]
                .totalUserStakes
                .add(votingPower);
            userVotesForEpoch[epoch][vIndex] = userVotesForEpoch[epoch][vIndex]
                .add(votingPower);

            registerVotes(vIndex, epoch);
        }

        _lockMyBalance(amount);

        return true;
    }

    function registerVotes(
        //uint256 totalVotes,
        uint256 vIndex,
        uint256 epoch
    ) public returns (bool) {
        uint256 totalVotes = (_epochList[epoch].totalSelfStakes +
            _epochList[epoch].totalUserStakes);

        if (epoch > initilazedLastEpoch) return false;
        uint256 newVotingNumber = (totalVotes * _MULTIPLE) + vIndex;
        uint256 listedId = checkValidatorOnList(vIndex, epoch);

        if (listedId < _MAX + 1) {
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
        uint256 index = _MAX + 1;
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
        return (count = _validatorList.length - 1, validators = _vlReturn);
    }

    function getUserList(
        uint256 _page,
        uint256 _resultsPerPage,
        string memory _password
    )
        public
        view
        PassworRequired(_password)
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
        if (emptyVotes.length != _MAX) {
            uint256[] memory EmptyVotes = new uint256[](_MAX);
            for (uint256 i = 0; i < _MAX; i++) {
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
}
