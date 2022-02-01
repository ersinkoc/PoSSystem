// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Data {
    struct User {
        address user;
        uint256 totalRewards;
    }

    // getUserList
    struct SummaryOfUser {
        uint256 index;
        address user;
        uint256 totalRewards;
        uint256 lockedBalance;
        uint256 unlockedBalance;
    }

    struct Epoch {
        uint256 epoch;
        uint256 totalRewards;
        uint256 totalSelfStakes;
        uint256 totalUserStakes;
        uint256 totalRewardScore;
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

    struct Vote {
        address user;
        address validator;
        uint256 startEpoch;
        uint256 endEpoch;
        bool active;
        uint256 amount;
        VotingType votingType;
    }

    struct UserVotes {
        address user;
        Vote[] user_votes;
    }

    struct ValidatorVotes {
        address validator;
        Vote[] user_votes;
    }

    struct Deposit {
        //address user;
        uint256 amount;
        uint256 epoch;
    }

    struct UserDeposit {
        address user;
        Deposit[] user_deposits;
    }

    struct ResignBalance {
        uint256 releaseEpoch;
        uint256 amount;
    }

    /** Enums */

    enum BalanceTypes {
        LOCKED,
        UNLOCKED
    }

    enum VotingType {
        SELFSTAKE,
        USERSTAKE
    }

    ///
}
