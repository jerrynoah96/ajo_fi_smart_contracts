# Technical Documentation

## System Architecture

```mermaid
graph TD
    A[User] -->|Stakes LP| B[Credit System]
    A -->|Requests Validation| C[Validator]
    C -->|Assigns Credits| B
    B -->|Credit Check| D[Purse Factory]
    D -->|Creates| E[Purse Contract]
    A -->|Joins| E
    E -->|Updates| B
```

## Contract Specifications

### 1. CreditSystem.sol
The central contract managing credit scores and validator governance.

#### Key Components:
- Credit Tracking
- Validator Management
- LP Staking
- Price Oracle Integration

```mermaid
classDiagram
    class CreditSystem {
        +userCredits: mapping
        +validators: mapping
        +whitelistedPools: mapping
        +stakeLPToken()
        +registerValidator()
        +assignCredits()
        +calculateLPCredits()
    }
```

#### Credit Mechanisms:
1. **LP Staking**
   - Users stake LP tokens from whitelisted pools
   - Credits = LP Value × Credit Ratio
   - Time-locked positions
   
2. **Validator Endorsement**
   - Validators stake USDC/USDT
   - Can assign credits up to validation power
   - Reputation affects credit assignment power

3. **Administrative Assignment**
   - Owner can assign credits to validators
   - Used for institutional integrations

### 2. PurseFactory.sol
Factory contract for creating new thrift groups.

```mermaid
sequenceDiagram
    participant User
    participant PurseFactory
    participant CreditSystem
    participant Purse

    User->>CreditSystem: Get Credits
    User->>PurseFactory: Create Purse
    PurseFactory->>CreditSystem: Check Credits
    PurseFactory->>Purse: Deploy New Purse
    Purse->>CreditSystem: Register with Credit System
```

#### Features:
- Purse creation with credit requirements
- Member tracking
- Chat ID integration
- Factory pattern implementation

### 3. Purse.sol
Individual thrift group contract.

#### States:
```mermaid
stateDiagram-v2
    [*] --> Open
    Open --> Closed: Max Members Joined
    Closed --> Terminated: All Rounds Complete
    Open --> Terminated: Emergency Stop
```

#### Key Features:
- Position-based membership
- Automated round progression
- Credit requirement enforcement
- Donation tracking

## Validator System

### Reputation Mechanism
```mermaid
graph LR
    A[Successful Endorsement] -->|+1 Point| B[Reputation Score]
    C[Failed Endorsement] -->|-1 Point| B
    B -->|>80% Success| D[Increased Power]
    B -->|<50% Success| E[Decreased Power]
    B -->|<30 Points| F[Deactivation]
```

### Validator Economics
- Initial Stake: 10,000 USDC/USDT
- Fee Range: 0-10%
- Bonus Multiplier: 1x-2x
- Slashing Conditions:
  1. User defaults
  2. Low reputation
  3. Inactivity

## LP Staking Mechanism

### Credit Calculation
```mermaid
graph TD
    A[LP Token Amount] -->|Get Reserves| B[Pool Value]
    B -->|Calculate Share| C[User's Value]
    C -->|Apply Ratio| D[Base Credits]
    D -->|Apply Limits| E[Final Credits]
```

### Pool Parameters
- Credit Ratio: Pool-specific
- Minimum Stake Time
- Maximum Credit Limit
- Price Feed Requirements

## Security Features

### Credit System
1. **Access Control**
   - Ownable for admin functions
   - Validator requirements
   - Credit assignment limits

2. **Economic Security**
   - Validator stakes
   - Time locks
   - Reputation system

3. **Emergency Controls**
   - System pause
   - Credit freezing
   - Validator deactivation

### Purse Security
1. **Member Protection**
   - Position verification
   - Donation tracking
   - Credit requirements

2. **Fund Safety**
   - Direct transfers
   - Balance tracking
   - Emergency exits

## Integration Points

### External Systems
1. **Price Oracles**
   - Token price feeds
   - LP value calculation
   - Update frequency checks

2. **Token Standards**
   - ERC20 for tokens
   - LP token interfaces
   - Stable coin integration

### User Integration
```mermaid
sequenceDiagram
    participant User
    participant DApp
    participant Contracts
    participant Oracle

    User->>DApp: Connect Wallet
    DApp->>Contracts: Get Credit Status
    DApp->>Oracle: Get LP Values
    User->>DApp: Stake LP/Join Purse
    DApp->>Contracts: Execute Transaction
    Contracts->>DApp: Update Status
```

## Error Handling

### Credit System Errors
- Insufficient credits
- Invalid validator status
- Price feed staleness
- LP token restrictions

### Purse Errors
- Position conflicts
- Membership limits
- Timing restrictions
- Donation requirements

## Upgrade Considerations

1. **Proxy Pattern**
   - Future upgrades
   - State preservation
   - Version control

2. **Data Migration**
   - Credit history
   - Validator status
   - LP positions

3. **Backward Compatibility**
   - Interface stability
   - Event compatibility
   - Function signatures 