# Decentralized Credit-Based Thrift System

A blockchain-based thrift (rotating savings) system with credit-based membership and validator governance.

## Overview

This project implements a decentralized rotating savings system (also known as "Ajo" in some cultures) where users can participate in thrift groups based on their credit scores. The system includes:

1. A credit system where users can obtain credits through:
   - Staking ERC20 tokens
   - Receiving validation from trusted validators
   - Administrative assignments

2. Validator system where validators:
   - Stake tokens to back their endorsements
   - Validate users and assign them credits
   - Are penalized if users they validate default

3. Purse system (thrift groups) where members:
   - Join with a required credit amount
   - Make regular contributions
   - Receive payouts according to their position in rotation
   - Face penalties for defaulting

## Key Features

- Credit-based membership requiring validator endorsement or token staking
- Validator stake-based accountability system
- Role-based access control for system administration
- Automated rotation savings with configurable parameters
- Default handling with validator penalties
- Whitelisted token registry for staking
- Multiple credit acquisition methods with time-locked operations
- Factory pattern for creating validators and purses

## Contract Architecture

```
├── Core Contracts
│   ├── CreditSystem.sol - Main credit management system
│   ├── TokenRegistry.sol - Registry for whitelisted tokens
│   ├── ValidatorFactory.sol - Factory for creating validator instances
│   ├── Validator.sol - Validator logic and stake management
│   ├── PurseFactory.sol - Factory for creating thrift groups
│   └── Purse.sol - Individual thrift group logic
│
├── Interfaces
│   ├── ICreditSystem.sol - Credit system interface
│   ├── ITokenRegistry.sol - Token registry interface
│   ├── IValidatorFactory.sol - Validator factory interface
│   └── IValidator.sol - Validator interface
│
├── Access
│   └── Role-based access control components
│
└── Mocks (for testing)
    ├── MockERC20.sol - Mock ERC20 token implementation
    └── MockStablecoin.sol - Mock USDC/USDT implementation
```

## Getting Started

### Prerequisites

- Node.js v16+ and npm
- Hardhat

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/ajo_fi_smart_contracts.git
cd ajo_fi_smart_contracts

# Install dependencies
npm install
```

### Configuration

Copy the example environment file:

```bash
cp .env.example .env
```

Then edit `.env` with your configuration:

```env
# Blockchain API Keys
ALCHEMY_API_KEY=your_alchemy_api_key_here
ETHERSCAN_API_KEY=your_etherscan_api_key_here

# Network URLs (optional)
SEPOLIA_URL=https://eth-sepolia.g.alchemy.com/v2/your_key_here
MAINNET_URL=https://eth-mainnet.g.alchemy.com/v2/your_key_here

# Deployment Account
PRIVATE_KEY=your_private_key_here

# Network Options
FORK_MAINNET=false
ENABLE_MAINNET=false
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

### Local Development

Start a local node:

```bash
# Start a local Hardhat node
npx hardhat node

# Deploy to local node in a new terminal
npx hardhat run scripts/deploy.ts --network localhost
```

### Deployment

```bash
# Deploy to Sepolia testnet
npx hardhat run scripts/deploy.ts --network sepolia

# Deploy to mainnet (requires ENABLE_MAINNET=true in .env)
npx hardhat run scripts/deploy.ts --network mainnet
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

## Advanced Configuration

The project uses a custom Hardhat configuration with several features:

- Multiple compiler versions support
- Gas reporting
- Network-specific settings
- TypeChain for TypeScript integration

Modify `hardhat.config.ts` for additional customization:

```typescript
// Example: Configure gas reporter
gasReporter: {
  enabled: true,
  currency: "USD",
  outputFile: "gas-report.txt",
  noColors: false,
  token: "ETH"
}
```

## Security Considerations

- Uses OpenZeppelin's AccessControl for role-based permissions
- Implements ReentrancyGuard for all functions handling token transfers
- Credit assignments and reductions are protected with authorization checks
- Time-locked operations for token staking (minimum stake time)
- Validator stake is at risk if validated users default
- Maximum limits on purse sizes and member counts
- Explicit error handling with custom error types
- Batch processing to prevent gas limit issues
- Factory pattern for controlled deployment of critical components

## Contract Verification

After deployment, verify contracts on Etherscan:

```bash
npx hardhat verify --network sepolia DEPLOYED_CONTRACT_ADDRESS "constructor_arg_1" "constructor_arg_2"
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
