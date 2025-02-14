# Decentralized Credit-Based Thrift System

A blockchain-based thrift (rotating savings) system with credit-based membership and validator governance.

## Overview

This project implements a decentralized thrift system where users can participate in rotating savings groups based on their credit scores. Credits can be obtained through:
1. LP token staking
2. Validator endorsements
3. Administrative assignments

## Key Features

- Credit-based membership system
- LP token staking with configurable ratios
- Validator governance with reputation system
- Automated rotation and distribution
- Multiple credit acquisition methods

## Contract Architecture

```
├── Core Contracts
│   ├── CreditSystem.sol - Main credit management system
│   ├── PurseFactory.sol - Factory for creating thrift groups
│   └── Purse.sol - Individual thrift group logic
│
├── Interfaces
│   └── IPriceOracle.sol - Price feed interface
│
└── Mocks (for testing)
    ├── MockPriceOracle.sol - Mock price feed implementation
    ├── MockLPToken.sol - Mock LP token for testing
    └── MockStablecoin.sol - Mock USDC/USDT implementation
```

## Getting Started

### Prerequisites

- Node.js v14+ and npm
- Hardhat

### Installation

```bash
npm install
```

### Configuration

Create a `.env` file:

```env
PRIVATE_KEY=your_private_key
ALCHEMY_API_KEY=your_alchemy_key
ETHERSCAN_API_KEY=your_etherscan_key
```

### Running Tests

```bash
# Run all tests
npx hardhat test

# Run specific test file
npx hardhat test test/creditSystem.test.ts

# Run with gas reporting
REPORT_GAS=true npx hardhat test

# Run with coverage
npx hardhat coverage
```

### Deployment

```bash
# Deploy to local hardhat network
npx hardhat run scripts/deploy.ts

# Deploy to testnet
npx hardhat run scripts/deploy.ts --network goerli
```

## Testing Documentation

### Test Structure

```
test/
├── creditSystem.test.ts - Credit system core functionality tests
├── purse.test.ts - Thrift group functionality tests
└── test-utils.ts - Testing utilities
```

### Test Categories

1. Credit System Tests
   - Validator registration and management
   - LP token staking and credit calculation
   - Credit assignment and reduction
   - Integration with purse creation

2. Purse Tests
   - Purse creation and membership
   - Rotation and distribution
   - Credit requirement validation
   - Member interactions

3. Integration Tests
   - End-to-end thrift cycle
   - Credit-based restrictions
   - Validator incentives

### Running Specific Test Suites

```bash
# Run credit system tests
npx hardhat test test/creditSystem.test.ts

# Run purse tests
npx hardhat test test/purse.test.ts

# Run with detailed logging
npx hardhat test --verbose
```

## Security Considerations

- All contracts use OpenZeppelin's secure implementations
- Credit assignments are protected by validator stakes
- Time-locked operations for LP staking
- Reputation-based validator system
- Emergency pause functionality

## Contract Verification

After deployment, verify contracts on Etherscan:

```bash
npx hardhat verify --network goerli DEPLOYED_CONTRACT_ADDRESS constructor_argument_1 constructor_argument_2
```

## Performance Optimizations

For faster development:
```bash
export TS_NODE_TRANSPILE_ONLY=1
```

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a new Pull Request

## License

MIT
