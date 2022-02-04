// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
    uint256[] voteX;
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
    uint256 reward;
    bool claimed;
}

struct UserVotesSummary {
    Vote[] userVotes;
}

struct ValidatorSummary {
    uint256 vIndex;
    uint256 totalVotes;
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

enum BalanceChange {
    ADD,
    SUB
}
