// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/ILPToken.sol";
import "./access/Roles.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";

/// @title Credit System for Purse Protocol
/// @notice Manages credit allocation through LP staking
contract CreditSystem is AccessControl, ReentrancyGuard, Pausable {
    struct LPPool {
        bool isWhitelisted;
        address token0;
        address token1;
        uint256 creditRatio; // How much credit per $1 of LP (in basis points)
        uint256 minStakeTime; // Minimum time LP must be staked
        uint256 maxCreditLimit; // Maximum credits that can be obtained from this pool
        uint256 totalStaked;
        uint256 totalCreditsIssued;
    }

    struct UserLPStake {
        uint256 amount;
        uint256 timestamp;
        uint256 creditsIssued;
    }

    // State variables
    mapping(address => uint256) public userCredits;
    mapping(address => LPPool) public whitelistedPools;
    mapping(address => mapping(address => UserLPStake)) public userLPStakes;
    mapping(address => uint256) public userPurseCount;
    mapping(address => bool) public authorizedPurses;
    mapping(address => bool) public authorizedFactories;
    
    IERC20 public immutable USDC;
    IERC20 public immutable USDT;
    IPriceOracle public priceOracle;
    
    // Constants
    uint256 public constant MAX_PURSES_PER_USER = 5;

    // Remove immutable keyword
    IValidatorFactory public validatorFactory;

    // Add mapping for user-validator relationship
    mapping(address => address) public userValidators;

    // Events
    event LPStaked(address indexed user, address indexed lpToken, uint256 amount, uint256 credits);
    event LPUnstaked(address indexed user, address indexed lpToken, uint256 amount);
    event CreditsReduced(address indexed user, uint256 amount, string reason);
    event PurseJoined(address indexed user, address indexed purse);
    event PurseLeft(address indexed user, address indexed purse);
    event FactoryRegistered(address indexed factory);
    event CreditsAssigned(address indexed from, address indexed to, uint256 amount);
    event ValidatorFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event CreditsTransferred(address indexed from, address indexed to, uint256 amount);
    event UserValidatorSet(address indexed user, address indexed validator);

    constructor(
        address _usdc, 
        address _usdt, 
        address _priceOracle,
        address _validatorFactory
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        USDC = IERC20(_usdc);
        USDT = IERC20(_usdt);
        priceOracle = IPriceOracle(_priceOracle);
        validatorFactory = IValidatorFactory(_validatorFactory);
    }

    function whitelistLPPool(
        address _lpToken,
        uint256 _creditRatio,
        uint256 _minStakeTime,
        uint256 _maxCreditLimit
    ) external onlyRole(Roles.ADMIN_ROLE) {
        ILPToken lpToken = ILPToken(_lpToken);
        whitelistedPools[_lpToken] = LPPool({
            isWhitelisted: true,
            token0: lpToken.token0(),
            token1: lpToken.token1(),
            creditRatio: _creditRatio,
            minStakeTime: _minStakeTime,
            maxCreditLimit: _maxCreditLimit,
            totalStaked: 0,
            totalCreditsIssued: 0
        });
    }

    // TODO : update this to just stake whitelisted tokens
    function stakeLPToken(address _lpToken, uint256 _amount) external nonReentrant {
        require(whitelistedPools[_lpToken].isWhitelisted, "LP not whitelisted");
        
        IERC20(_lpToken).transferFrom(msg.sender, address(this), _amount);
        
        uint256 creditAmount = calculateLPCredits(_lpToken, _amount);
        userCredits[msg.sender] += creditAmount;
        userLPStakes[msg.sender][_lpToken] = UserLPStake({
            amount: _amount,
            timestamp: block.timestamp,
            creditsIssued: creditAmount
        });
        
        emit LPStaked(msg.sender, _lpToken, _amount, creditAmount);
    }

    function unstakeLPToken(address _lpToken) external nonReentrant {
        UserLPStake storage stake = userLPStakes[msg.sender][_lpToken];
        require(stake.amount > 0, "No stake found");
        require(
            block.timestamp >= stake.timestamp + whitelistedPools[_lpToken].minStakeTime,
            "Minimum stake time not met"
        );

        uint256 amount = stake.amount;
        uint256 creditsIssued = stake.creditsIssued;

        require(userCredits[msg.sender] >= creditsIssued, "Insufficient credits");
        
        userCredits[msg.sender] -= creditsIssued;
        delete userLPStakes[msg.sender][_lpToken];
        
        IERC20(_lpToken).transfer(msg.sender, amount);
        
        emit LPUnstaked(msg.sender, _lpToken, amount);
    }

    function assignCredits(address _user, uint256 _amount) external {
        // Check if caller is authorized
        bool isAuthorized = 
            authorizedFactories[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender) ||
            validatorFactory.isValidatorContract(msg.sender) || 
            authorizedPurses[msg.sender]; // Purse contract
        
        require(isAuthorized, "Not authorized");
        
        userCredits[_user] += _amount;
        emit CreditsAssigned(msg.sender, _user, _amount);
    }

    function reduceCredits(address _user, uint256 _amount) external {
        // Check if caller is authorized
        bool isAuthorized = 
            authorizedFactories[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender) ||
            validatorFactory.isValidatorContract(msg.sender) || // Validator contract
            authorizedPurses[msg.sender]; // Purse contract
        
        require(isAuthorized, "Not authorized");
        require(userCredits[_user] >= _amount, "Insufficient credits");
        
        userCredits[_user] -= _amount;
        emit CreditsReduced(_user, _amount, "Manual reduction");
    }

    function reduceCreditsForDefault(
        address _user,
        address _recipient,
        uint256 _amount,
        address _validator
    ) external {
        require(authorizedPurses[msg.sender], "Not authorized purse");
        require(userValidators[_user] == _validator, "Invalid validator for user");
        
        // Reduce user credits
        userCredits[_user] = userCredits[_user] > _amount ? 
            userCredits[_user] - _amount : 0;

        // Get validator for this user
        address validatorAddress = validatorFactory.getValidatorContract(_validator);
        require(validatorAddress != address(0), "No validator found");

        // Reduce validator stake if user defaults
        IValidator(validatorAddress).handleDefaulterPenalty(_user, _recipient, _amount);

        emit CreditsReduced(_user, _amount, "Default penalty");
    }

    function calculateLPCredits(address _lpToken, uint256 _amount) 
        public 
        view 
        returns (uint256) 
    {
        LPPool memory pool = whitelistedPools[_lpToken];
        require(pool.isWhitelisted, "LP not whitelisted");

        ILPToken lpToken = ILPToken(_lpToken);
        (uint112 reserve0, uint112 reserve1,) = lpToken.getReserves();
        uint256 totalSupply = lpToken.totalSupply();
        
        uint256 reserve0In18 = uint256(reserve0) * 10**12;
        uint256 reserve1In18 = uint256(reserve1) * 10**12;
        
        uint256 token0Price = priceOracle.getPrice(pool.token0);
        uint256 token1Price = priceOracle.getPrice(pool.token1);
        
        uint256 totalPoolValue = (reserve0In18 * token0Price + reserve1In18 * token1Price) / 1e18;
        uint256 userShare = (_amount * 1e18) / totalSupply;
        uint256 userValue = (totalPoolValue * userShare) / 1e18;
        uint256 credits = (userValue * pool.creditRatio) / 10000;
        
        return credits > pool.maxCreditLimit ? pool.maxCreditLimit : credits;
    }

    function registerPurse(address _purse) external {
        require(authorizedFactories[msg.sender], "Not authorized factory");
        authorizedPurses[_purse] = true;
    }

    function authorizeFactory(address _factory) external onlyRole(Roles.ADMIN_ROLE) {
        require(_factory != address(0), "Invalid factory address");
        authorizedFactories[_factory] = true;
        emit FactoryRegistered(_factory);
    }

    function pause() external onlyRole(Roles.ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.ADMIN_ROLE) {
        _unpause();
    }

    function setValidatorFactory(address _validatorFactory) external onlyRole(Roles.ADMIN_ROLE) {
        require(_validatorFactory != address(0), "Invalid validator factory");
        require(_validatorFactory != address(validatorFactory), "Same validator factory");
        
        address oldFactory = address(validatorFactory);
        validatorFactory = IValidatorFactory(_validatorFactory);
        
        emit ValidatorFactoryUpdated(oldFactory, _validatorFactory);
    }

    // Update the setUserValidator function to check if user is already validated
    function setUserValidator(address _user, address _validator) external {
        require(
            authorizedFactories[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender) ||
            validatorFactory.getValidatorContract(msg.sender) != address(0),
            "Not authorized"
        );
        
        // If user already has a validator, ensure it's being cleared or replaced by the same validator
        if (userValidators[_user] != address(0) && userValidators[_user] != _validator) {
            require(
                _validator == address(0) || // Clearing validator
                msg.sender == userValidators[_user] || // Current validator updating
                hasRole(Roles.ADMIN_ROLE, msg.sender), // Admin can override
                "User already validated by another validator" 
            );
        }
        
        userValidators[_user] = _validator;
        emit UserValidatorSet(_user, _validator);
    }

    // Add a function to check if user is validated by a specific validator
    function isUserValidatedBy(address _user, address _validator) external view returns (bool) {
        return userValidators[_user] == _validator;
    }

    function transferCredits(address _from, address _to, uint256 _amount) external {
        // Only validators or admin can transfer credits
        require(
            validatorFactory.getValidatorContract(msg.sender) != address(0) || 
            hasRole(Roles.ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        
        require(userCredits[_from] >= _amount, "Insufficient credits");
        
        userCredits[_from] -= _amount;
        userCredits[_to] += _amount;
        
        emit CreditsTransferred(_from, _to, _amount);
    }
} 