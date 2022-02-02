// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

contract VotingSystem {
    constructor() {
        InitFirstEpoch();
    }

    function InitFirstEpoch() internal {
        _epochList.push();
        if (emptyVotes.length != _MAX) {
            uint256[] memory EmptyVotes = new uint256[](_MAX);
            for (uint256 i = 0; i < _MAX; i++) {
                EmptyVotes[i] = uint256(0);
            }
            emptyVotes = EmptyVotes;
        }
        _epochList[0] = Epoch({epoch: 0, voteX: emptyVotes});
    }

    uint256[] public emptyVotes;

    struct ValidatorSummary {
        uint256 vIndex;
        uint256 totalVotes;
    }

    struct Epoch {
        uint256 epoch;
        uint256[] voteX;
    }

    Epoch[] public _epochList;

    uint256 private constant _MAX = 5;
    uint256 private constant _MULTIPLE = 1_000_000_000_000;

    uint256 public initilazedLastEpoch = 0;

    function getEpoch(uint256 _epoch)
        public
        view
        returns (uint256, uint256[] memory)
    {
        return (_epochList[_epoch].epoch, _epochList[_epoch].voteX);
    }

    function initEpoch() public returns (uint256) {
        uint256 _epoch = initilazedLastEpoch + 1;
        _epochList.push();
        if (emptyVotes.length != _MAX) {
            uint256[] memory EmptyVotes = new uint256[](_MAX);
            for (uint256 i = 0; i < _MAX; i++) {
                EmptyVotes[i] = uint256(0);
            }
            emptyVotes = EmptyVotes;
        }
        _epochList[_epoch] = Epoch({epoch: _epoch, voteX: emptyVotes});
        initilazedLastEpoch = initilazedLastEpoch + 1;
        return _epoch;
    }

    function register() public returns (bool) {
        for (uint256 i = 0; i < 3; i++) {
            registerVotesForMultipleEpoch((i * 10**2) + 4, i + 1, 1, 7);
        }

        return true;
    }

    function registerVotesForMultipleEpoch(
        uint256 totalVotes,
        uint256 _vIndex,
        uint256 _startEpoch,
        uint256 epoch
    ) public returns (bool) {
        if (epoch == 0 || epoch > 7) epoch = 7;
        for (uint256 i = _startEpoch; i < _startEpoch + epoch; i++) {
            registerVotes(totalVotes, _vIndex, i);
        }
        return true;
    }

    function registerVotes(
        uint256 totalVotes,
        uint256 vIndex,
        uint256 epoch
    ) public returns (bool) {
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

    function getMinimumVotes(uint256 epoch) public view returns (uint256) {
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
        public
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
}
