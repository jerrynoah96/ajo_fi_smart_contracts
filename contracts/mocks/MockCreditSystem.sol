// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../interfaces/IPriceOracle.sol';
import '../access/Roles.sol';

contract MockCreditSystem is AccessControl {
    IPriceOracle public priceOracle;
    mapping(address => uint256) public userCredits;
    mapping(address => bool) public whitelistedLPPools;
    mapping(address => uint256) public creditRatios;
    mapping(address => bool) public authorizedPurses;
    mapping(address => bool) public authorizedFactories;
    mapping(address => bool) public validators;
    mapping(address => address) public userToValidator;

    struct LPPool {
        bool isWhitelisted;
        uint256 creditRatio;
        uint256 minStakeTime;
        uint256 maxCreditLimit;
    }

    mapping(address => LPPool) public whitelistedPools;

    event LPStaked(
        address indexed user,
        address indexed lpToken,
        uint256 amount,
        uint256 credits
    );
    event ValidatorRegistered(address validator);
    event FactoryRegistered(address factory);

    error NotAuthorizedOnlyValidatorOrFactory();
    error LPTokenNotWhitelisted();
    error UserAlreadyHasValidator();
    error InvalidValidatorAddress();
    error NoValidatorToRemove();
    error NotAuthorizedForRemoval();

    constructor(address _priceOracle) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        priceOracle = IPriceOracle(_priceOracle);
    }

    modifier onlyValidatorOrFactory() {
        if (
            !hasRole(Roles.VALIDATOR_ROLE, msg.sender) &&
            !hasRole(Roles.FACTORY_ROLE, msg.sender) &&
            !hasRole(Roles.ADMIN_ROLE, msg.sender)
        ) {
            revert NotAuthorizedOnlyValidatorOrFactory();
        }
        _;
    }

    function registerPurseFactory(
        address _factory
    ) external onlyRole(Roles.ADMIN_ROLE) {
        authorizedFactories[_factory] = true;
        emit FactoryRegistered(_factory);
    }

    function registerValidator(uint256 fee) external {
        validators[msg.sender] = true;
        emit ValidatorRegistered(msg.sender);
    }

    function registerPurse(address _purse) external {
        if (!authorizedFactories[msg.sender]) revert NotAuthorized();
        authorizedPurses[_purse] = true;
    }

    function whitelistLPPool(
        address lpToken,
        uint256 creditRatio,
        uint256 minStakeTime,
        uint256 maxCreditLimit
    ) external onlyRole(Roles.ADMIN_ROLE) {
        whitelistedPools[lpToken] = LPPool({
            isWhitelisted: true,
            creditRatio: creditRatio,
            minStakeTime: minStakeTime,
            maxCreditLimit: maxCreditLimit
        });
    }

    function calculateLPCredits(
        address lpToken,
        uint256 amount
    ) public view returns (uint256) {
        if (!whitelistedPools[lpToken].isWhitelisted)
            revert LPTokenNotWhitelisted();

        // Get LP token price from oracle (in 18 decimals)
        uint256 lpPrice = priceOracle.getPrice(lpToken);

        // First divide by 1e18 to avoid overflow
        uint256 totalValue = (amount / 1e18) * lpPrice;

        // Apply credit ratio (in basis points)
        uint256 credits = (totalValue * whitelistedPools[lpToken].creditRatio) /
            10000;

        return
            credits > whitelistedPools[lpToken].maxCreditLimit
                ? whitelistedPools[lpToken].maxCreditLimit
                : credits;
    }

    function stakeLPToken(address lpToken, uint256 amount) external {
        uint256 credits = calculateLPCredits(lpToken, amount);
        userCredits[msg.sender] += credits;
        emit LPStaked(msg.sender, lpToken, amount, credits);
    }

    error InsufficientCredits();
    error NotAuthorized();

    function reduceCredits(address user, uint256 amount) external {
        if (!authorizedFactories[msg.sender]) revert NotAuthorized();
        if (userCredits[user] < amount) revert InsufficientCredits();
        userCredits[user] -= amount;
    }

    function assignCredits(
        address user,
        uint256 amount
    ) external onlyValidatorOrFactory {
        userCredits[user] += amount;
    }

    function adminAssignCredits(
        address user,
        uint256 amount
    ) external onlyRole(Roles.ADMIN_ROLE) {
        userCredits[user] += amount;
    }

    function getUserValidator(address user) external view returns (address) {
        return userToValidator[user];
    }

    function setUserValidator(
        address user,
        address validator
    ) external onlyValidatorOrFactory {
        if (userToValidator[user] != address(0))
            revert UserAlreadyHasValidator();
        if (validator == address(0)) revert InvalidValidatorAddress();
        userToValidator[user] = validator;
    }

    function removeUserValidator(address user) external {
        address currentValidator = userToValidator[user];
        if (
            msg.sender != currentValidator &&
            !hasRole(Roles.ADMIN_ROLE, msg.sender)
        ) {
            revert NotAuthorizedForRemoval();
        }
        if (currentValidator == address(0)) revert NoValidatorToRemove();
        delete userToValidator[user];
    }
}
