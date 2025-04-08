# Technical Documentation

## System Architecture

This document provides technical details about the Ajo Finance system, a credit-based thrift (rotating savings) platform built on Ethereum.

The system consists of the following core components:

1. **Credit System**: Manages user credits from token staking and validator endorsements
2. **Validator System**: Handles user validation and stake management
3. **Purse System**: Implements the rotating savings groups

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│                 │      │                 │      │                 │
│  Token Registry ◄──────┤  Credit System  ├──────►  PurseFactory   │
│                 │      │                 │      │                 │
└────────┬────────┘      └────────┬────────┘      └────────┬────────┘
         │                        │                        │
         │                        │                        │
         │                        ▼                        ▼
┌────────▼────────┐      ┌─────────────────┐      ┌─────────────────┐
│                 │      │                 │      │                 │
│  ERC20 Tokens   │      │ValidatorFactory │      │  Purse Contract │
│                 │      │                 │      │                 │
└─────────────────┘      └────────┬────────┘      └─────────────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │                 │
                         │    Validator    │
                         │                 │
                         └─────────────────┘
```

## Core Contracts

### 1. CreditSystem.sol

The central contract managing credit allocation and validator relationships.

**Key Features:**
- Token staking mechanism to earn credits
- Credit assignment and validation
- Purse registration and credit management
- User-validator relationship tracking
- Default handling

**Key State Variables:**
- `userCredits`: Tracks credit balances for each user
- `userTokenStakes`: Records token staking details
- `authorizedPurses`: List of authorized purse contracts
- `authorizedFactories`: Factory contracts with special permissions

**Key Functions:**
- `stakeToken()`: Allows users to stake tokens for credits
- `unstakeToken()`: Withdraws staked tokens after time lock
- `assignCredits()`: Assigns credits to a user
- `reduceCredits()`: Removes credits from a user
- `commitCreditsToPurse()`: Commits user credits to a purse
- `handleUserDefault()`: Processes user defaults in purses

### 2. TokenRegistry.sol

Tracks whitelisted tokens that can be used in the system.

**Key Features:**
- Token whitelisting management
- Simple admin interface

**Key Functions:**
- `setTokenWhitelist()`: Sets a token's whitelist status
- `isTokenWhitelisted()`: Checks if a token is whitelisted

### 3. ValidatorFactory.sol

Factory contract for creating and managing validator instances.

**Key Features:**
- Validator creation with configurable parameters
- Token whitelisting for staking
- Minimum stake requirements

**Key Functions:**
- `createValidator()`: Creates a new validator contract
- `getValidatorContract()`: Retrieves a validator's contract address
- `setTokenWhitelist()`: Manages supported tokens for validator staking

### 4. Validator.sol

Individual validator contracts that stake tokens and validate users.

**Key Features:**
- User validation with customizable fees
- Stake management
- Default handling and penalties

**Key Functions:**
- `validateUser()`: Validates a user and assigns credits
- `invalidateUser()`: Removes validation from a user
- `handleDefaulterPenalty()`: Processes penalties when validated users default
- `addStake()`: Adds more stake to the validator

### 5. PurseFactory.sol

Factory contract for creating new thrift groups (purses).

**Key Features:**
- Purse creation with configurable parameters
- Credit requirement enforcement
- Integration with credit system

**Key Functions:**
- `createPurse()`: Creates a new purse contract
- `getPurseCount()`: Gets the total number of purses created

### 6. Purse.sol

Individual thrift group contract managing contributions and payouts.

**Key Features:**
- Position-based membership
- Scheduled contributions
- Rotational payouts
- Default handling

**Key Functions:**
- `joinPurse()`: Allows users to join a purse
- `contribute()`: Makes a contribution for the current round
- `resolveRound()`: Processes the end of a round
- `processBatchDefaulters()`: Handles defaulters in batches

## Credit Mechanisms

1. **Token Staking**
   - Users stake ERC20 tokens to receive credits
   - Credits are locked for a minimum period
   - Credits can be released by unstaking

2. **Validator Endorsement**
   - Validators stake tokens as collateral
   - Validators can assign credits to users they trust
   - Validators face penalties if validated users default

3. **Purse Participation**
   - Credits are committed when joining a purse
   - Credits are returned/redistributed when purse completes
   - Validators may receive credits from defaulters

## Purse Lifecycle

1. **Creation**: Admin creates purse with parameters
2. **Joining**: Users join by selecting positions and committing credits
3. **Active**: Purse moves to active state when full
4. **Contributions**: Members make regular contributions
5. **Payouts**: Members receive payouts according to position
6. **Completion**: Purse completes when all rounds finish

## Security Considerations

1. **Access Control**
   - Role-based access control using OpenZeppelin's patterns
   - Factory authorization for critical functions
   - Admin permissions for token whitelisting

2. **Economic Security**
   - Validator staking requirements
   - Time-locked token positions
   - Defaulter penalties

3. **Implementation Security**
   - Nonreentrant modifiers for external calls
   - Input validation
   - Custom error types
   - Batch processing for gas optimization 