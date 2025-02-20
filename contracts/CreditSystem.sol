// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import './interfaces/IPriceOracle.sol';
import './interfaces/ILPToken.sol';
import './access/Roles.sol';
import './interfaces/IValidatorFactory.sol';
import './interfaces/IValidator.sol';

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
    event LPStaked(
        address indexed user,
        address indexed lpToken,
        uint256 amount,
        uint256 credits
    );
    event LPUnstaked(
        address indexed user,
        address indexed lpToken,
        uint256 amount
    );
    event CreditsReduced(address indexed user, uint256 amount, string reason);
    event PurseJoined(address indexed user, address indexed purse);
    event PurseLeft(address indexed user, address indexed purse);
    event FactoryRegistered(address indexed factory);
    event CreditsAssigned(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event ValidatorFactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    // Add custom errors
    error NotAuthorizedPurse();
    error NoValidatorFound();
    error InvalidValidatorFactory();
    error SameValidatorFactory();
    error NotAuthorizedFactory();
    error InsufficientCredits();
    error InvalidValidator();
    error LPNotWhitelisted();
    error NoStakeFound();
    error MinimumStakeTimeNotMet();
    error NotAuthorized();
    error InvalidFactoryAddress();
    error LPNotWhitelistedForCredits();
    error UserAlreadyHasValidator();
    error LPTokenNotWhitelisted();

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

    function stakeLPToken(
        address _lpToken,
        uint256 _amount
    ) external nonReentrant {
        if (!whitelistedPools[_lpToken].isWhitelisted)
            revert LPNotWhitelisted();

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
        if (stake.amount == 0) revert NoStakeFound();
        if (
            block.timestamp <
            stake.timestamp + whitelistedPools[_lpToken].minStakeTime
        ) revert MinimumStakeTimeNotMet();

        uint256 amount = stake.amount;
        uint256 creditsIssued = stake.creditsIssued;

        if (userCredits[msg.sender] < creditsIssued)
            revert InsufficientCredits();

        userCredits[msg.sender] -= creditsIssued;
        delete userLPStakes[msg.sender][_lpToken];

        IERC20(_lpToken).transfer(msg.sender, amount);

        emit LPUnstaked(msg.sender, _lpToken, amount);
    }

    function assignCredits(address _user, uint256 _amount) external {
        if (
            !authorizedFactories[msg.sender] &&
            !hasRole(Roles.ADMIN_ROLE, msg.sender)
        ) revert NotAuthorized();
        userCredits[_user] += _amount;
        emit CreditsAssigned(msg.sender, _user, _amount);
    }

    function reduceCredits(address _user, uint256 _amount) external {
        if (!authorizedFactories[msg.sender] && !authorizedPurses[msg.sender])
            revert NotAuthorizedFactory();
        if (userCredits[_user] < _amount) revert InsufficientCredits();

        userCredits[_user] -= _amount;
        emit CreditsReduced(_user, _amount, ''); // Empty reason for normal reduction
    }

    function reduceCreditsForDefault(
        address _user,
        address _recipient,
        uint256 _amount,
        address _validator
    ) external {
        if (!authorizedPurses[msg.sender]) revert NotAuthorizedPurse();
        if (userValidators[_user] != _validator) revert InvalidValidator();

        // Reduce user credits
        userCredits[_user] = userCredits[_user] > _amount
            ? userCredits[_user] - _amount
            : 0;

        // Get validator for this user
        address validatorAddress = validatorFactory.getValidatorContract(
            _validator
        );
        if (validatorAddress == address(0)) revert NoValidatorFound();

        // Reduce validator stake if user defaults
        IValidator(validatorAddress).handleDefaulterPenalty(
            _user,
            _recipient,
            _amount
        );

        emit CreditsReduced(_user, _amount, 'Default penalty');
    }

    function calculateLPCredits(
        address _lpToken,
        uint256 _amount
    ) public view returns (uint256) {
        LPPool memory pool = whitelistedPools[_lpToken];
        if (!pool.isWhitelisted) revert LPNotWhitelistedForCredits();

        ILPToken lpToken = ILPToken(_lpToken);
        (uint112 reserve0, uint112 reserve1, ) = lpToken.getReserves();
        uint256 totalSupply = lpToken.totalSupply();

        uint256 reserve0In18 = uint256(reserve0) * 10 ** 12;
        uint256 reserve1In18 = uint256(reserve1) * 10 ** 12;

        uint256 token0Price = priceOracle.getPrice(pool.token0);
        uint256 token1Price = priceOracle.getPrice(pool.token1);

        uint256 totalPoolValue = (reserve0In18 *
            token0Price +
            reserve1In18 *
            token1Price) / 1e18;
        uint256 userShare = (_amount * 1e18) / totalSupply;
        uint256 userValue = (totalPoolValue * userShare) / 1e18;
        uint256 credits = (userValue * pool.creditRatio) / 10000;

        return credits > pool.maxCreditLimit ? pool.maxCreditLimit : credits;
    }

    function registerPurse(address _purse) external {
        if (!authorizedFactories[msg.sender]) revert NotAuthorizedFactory();
        authorizedPurses[_purse] = true;
    }

    function authorizeFactory(
        address _factory
    ) external onlyRole(Roles.ADMIN_ROLE) {
        if (_factory == address(0)) revert InvalidFactoryAddress();
        authorizedFactories[_factory] = true;
        emit FactoryRegistered(_factory);
    }

    function pause() external onlyRole(Roles.ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(Roles.ADMIN_ROLE) {
        _unpause();
    }

    function setValidatorFactory(
        address _validatorFactory
    ) external onlyRole(Roles.ADMIN_ROLE) {
        if (_validatorFactory == address(0)) revert InvalidValidatorFactory();
        if (_validatorFactory == address(validatorFactory))
            revert SameValidatorFactory();

        address oldFactory = address(validatorFactory);
        validatorFactory = IValidatorFactory(_validatorFactory);

        emit ValidatorFactoryUpdated(oldFactory, _validatorFactory);
    }

    // Add function to set user's validator
    function setUserValidator(address _user, address _validator) external {
        if (
            !authorizedFactories[msg.sender] &&
            !hasRole(Roles.ADMIN_ROLE, msg.sender)
        ) revert NotAuthorized();
        userValidators[_user] = _validator;
    }
}
