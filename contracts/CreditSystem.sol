// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./access/Roles.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/ITokenRegistry.sol";

/// @title Credit System for Purse Protocol
/// @notice Manages credit allocation through token staking
contract CreditSystem is AccessControl, ReentrancyGuard {
    struct UserTokenStake {
        uint256 amount;
        uint256 timestamp;
        uint256 creditsIssued;
        address token;
    }

    struct UserPurseCredit {
        uint256 amount;
        address validator;
        bool active;
    }

    // State variables
    mapping(address => uint256) public userCredits;
    mapping(address => mapping(address => UserTokenStake)) public userTokenStakes;
    mapping(address => uint256) public userPurseCount;
    mapping(address => bool) public authorizedPurses;
    mapping(address => bool) public authorizedFactories;
    
    // Constants
    uint256 public constant MAX_PURSES_PER_USER = 5;
    uint256 public constant MIN_STAKE_TIME = 1 days;

    IValidatorFactory public validatorFactory;
    ITokenRegistry public tokenRegistry;
    
    // Add mapping for user-validator relationship
    mapping(address => address) public userValidators;

    // Track credits committed to each purse by each user
    mapping(address => mapping(address => UserPurseCredit)) public userPurseCredits;

    // Track validator defaulter history
    mapping(address => mapping(address => uint256)) public validatorDefaulterHistory;

    // Events
    event TokenStaked(address indexed user, address indexed token, uint256 amount, uint256 credits);
    event TokenUnstaked(address indexed user, address indexed token, uint256 amount);
    event CreditsReduced(address indexed user, uint256 amount, string reason);
    event PurseJoined(address indexed user, address indexed purse);
    event PurseLeft(address indexed user, address indexed purse);
    event FactoryRegistered(address indexed factory);
    event CreditsAssigned(address indexed from, address indexed to, uint256 amount);
    event ValidatorFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event CreditsTransferred(address indexed from, address indexed to, uint256 amount);
    event UserValidatorSet(address indexed user, address indexed validator);
    event AdminCreditTransfer(address indexed from, address indexed to, uint256 amount);
    event TokenRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event CreditsCommitted(address indexed user, address indexed purse, uint256 amount, address indexed validator);
    event DefaultProcessed(address indexed user, address indexed purse, uint256 amount, address indexed validator, address recipient);
    event CreditsReleased(address indexed user, address indexed purse, uint256 amount, address indexed validator);
    event DefaulterPenaltyApplied(address indexed user, address indexed validator, uint256 amount);
    event DefaulterPenaltyFailed(address indexed user, address indexed validator, uint256 amount, bytes reason);

    // Custom errors
    error NotAuthorizedPurse();
    error NoValidatorForUser();
    error InsufficientCommittedCredits();

    constructor(
        address _validatorFactory,
        address _tokenRegistry
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        validatorFactory = IValidatorFactory(_validatorFactory);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
    }

    function stakeToken(address _token, uint256 _amount) external nonReentrant {
        require(tokenRegistry.isTokenWhitelisted(_token), "Token not whitelisted");
        
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        
        uint256 creditAmount = _amount;
        userCredits[msg.sender] += creditAmount;
        userTokenStakes[msg.sender][_token] = UserTokenStake({
            amount: _amount,
            timestamp: block.timestamp,
            creditsIssued: creditAmount,
            token: _token
        });
        
        emit TokenStaked(msg.sender, _token, _amount, creditAmount);
    }

    function unstakeToken(address _token, uint256 _amount) external nonReentrant {
        UserTokenStake storage stake = userTokenStakes[msg.sender][_token];
        require(stake.amount > 0, "No stake found");
        
        if (_amount == 0) {
            _amount = stake.amount;
        }
        
        require(_amount <= stake.amount, "Amount exceeds stake");
        
        require(
            block.timestamp >= stake.timestamp + MIN_STAKE_TIME,
            "Minimum stake time not met"
        );

        uint256 creditsToReduce = (stake.creditsIssued * _amount) / stake.amount;
        
        require(userCredits[msg.sender] >= creditsToReduce, "Insufficient credits");
        
        userCredits[msg.sender] -= creditsToReduce;
        
        if (_amount == stake.amount) {
            delete userTokenStakes[msg.sender][_token];
        } else {
            stake.amount -= _amount;
            stake.creditsIssued -= creditsToReduce;
        }
        
        IERC20(_token).transfer(msg.sender, _amount);
        
        emit TokenUnstaked(msg.sender, _token, _amount);
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


    function registerPurse(address _purse) external {
        require(authorizedFactories[msg.sender], "Not authorized factory");
        authorizedPurses[_purse] = true;
    }

    function authorizeFactory(address _factory) external onlyRole(Roles.ADMIN_ROLE) {
        require(_factory != address(0), "Invalid factory address");
        authorizedFactories[_factory] = true;
        emit FactoryRegistered(_factory);
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
        // Two authorized paths:
        // 1. Admin role can transfer anyone's credits
        // 2. Validator contract can transfer credits from users it has validated
        //    OR can transfer credits FROM the validator owner themselves
        
        address callerAsValidator = address(0);
        bool isValidatorContract = validatorFactory.isValidatorContract(msg.sender);
        
        if (isValidatorContract) {
            // Find which validator owner controls this validator contract
            for (uint i = 0; i < validatorFactory.getActiveValidators().length; i++) {
                address validator = validatorFactory.getActiveValidators()[i];
                if (validatorFactory.getValidatorContract(validator) == msg.sender) {
                    callerAsValidator = validator;
                    break;
                }
            }
            
            // Allow transfer if:
            // 1. FROM is the validator owner (for initial validation)
            // 2. OR user has been validated by this validator
            require(
                _from == callerAsValidator || // Validator transferring their own credits
                userValidators[_from] == callerAsValidator, // User validated by this validator
                "Not validated by this validator"
            );
        } else {
            // Not a validator contract, must be admin
            require(hasRole(Roles.ADMIN_ROLE, msg.sender), "Not authorized: admin role required");
        }
        
        require(userCredits[_from] >= _amount, "Insufficient credits");
        
        userCredits[_from] -= _amount;
        userCredits[_to] += _amount;
        
        // Log whether this was an admin transfer for transparency
        if (!isValidatorContract) {
            emit AdminCreditTransfer(_from, _to, _amount);
        }
        
        emit CreditsTransferred(_from, _to, _amount);
    }

    function setTokenRegistry(address _tokenRegistry) external onlyRole(Roles.ADMIN_ROLE) {
        require(_tokenRegistry != address(0), "Invalid token registry");
        address oldRegistry = address(tokenRegistry);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
        emit TokenRegistryUpdated(oldRegistry, _tokenRegistry);
    }

    /**
     * @notice Commit user credits to a specific purse with validator backing
     * @param _user User address
     * @param _purse Purse address
     * @param _amount Credit amount
     * @param _validator Validator address (can be zero if no validator)
     */
    function commitCreditsToPurse(
        address _user, 
        address _purse, 
        uint256 _amount, 
        address _validator
    ) external {
        require(
            authorizedFactories[msg.sender] || 
            authorizedPurses[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        
        // Ensure user has enough credits
        require(userCredits[_user] >= _amount, "Insufficient credits");
        
        // If validator is provided, ensure it's valid
        if (_validator != address(0)) {
            require(validatorFactory.getValidatorContract(_validator) != address(0), "Invalid validator");
        }
        
        // Reduce user's available credits
        userCredits[_user] -= _amount;
        
        // Record credit commitment to this purse
        userPurseCredits[_user][_purse] = UserPurseCredit({
            amount: _amount,
            validator: _validator,
            active: true
        });
        
        emit CreditsCommitted(_user, _purse, _amount, _validator);
    }

    /**
     * @notice Handle a user default in a purse
     * @param _user Defaulting user address
     * @param _purse Purse address
     * @param _amount Default amount
     * @param _token Token address
     * @param _recipient Address to receive slashed tokens
     */
    function handleUserDefault(
        address _user,
        address _purse,
        uint256 _amount,
        address _token,
        address _recipient
    ) external {
        // Check that caller is an authorized purse
        if (!authorizedPurses[_purse]) revert NotAuthorizedPurse();
        
        // Get the validator owner for this user's credit
        address validatorOwner = userPurseCredits[_user][_purse].validator;
        if (validatorOwner == address(0)) revert NoValidatorForUser();
        
        // Get the actual validator contract address
        address validatorContract = validatorFactory.getValidatorContract(validatorOwner);
        if (validatorContract == address(0)) revert ("Validator contract not found");
        
        // Get available user credits for this purse
        uint256 committedCredits = userPurseCredits[_user][_purse].amount;
        if (committedCredits < _amount) revert InsufficientCommittedCredits();
        
        // Reduce user's committed credits
        userPurseCredits[_user][_purse].amount -= _amount;
        
        // Update defaulter statistics
        validatorDefaulterHistory[validatorOwner][_user] += _amount;
        
        // Call the validator's handleDefaulterPenalty function
        try IValidator(validatorContract).handleDefaulterPenalty(_user, _recipient, _amount) {
            // Default successfully handled
            emit DefaulterPenaltyApplied(_user, validatorOwner, _amount);
        } catch (bytes memory reason) {
            // Log failure and continue
            emit DefaulterPenaltyFailed(_user, validatorOwner, _amount, reason);
            
            // Even if penalty application fails, we still count this as processed for the purse
            // This ensures the purse can continue operating even if a validator contract malfunctions
        }
    }

    /**
     * @notice Release committed credits after purse round completes
     * @param _user User address
     * @param _purse Purse address
     */
    function releasePurseCredits(address _user, address _purse) external  {
        require(
            authorizedPurses[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender),
            "Not authorized purse"
        );
        
        UserPurseCredit storage purseCredit = userPurseCredits[_user][_purse];
        require(purseCredit.active, "No active credits for purse");
        
        // Return credits to appropriate party
        if (purseCredit.validator != address(0)) {
            // Return to validator if user had one
            userCredits[purseCredit.validator] += purseCredit.amount;
        } else {
            // Return to user if they didn't have a validator
            userCredits[_user] += purseCredit.amount;
        }
        
        // Mark as inactive
        purseCredit.active = false;
        
        emit CreditsReleased(_user, _purse, purseCredit.amount, purseCredit.validator);
    }

    /**
     * @notice Get user credits committed to a purse
     * @param _user User address
     * @param _purse Purse address
     * @return amount Credit amount
     * @return validator Validator address (zero if none)
     * @return active Whether credits are active
     */
    function getUserPurseCredit(
        address _user, 
        address _purse
    ) external view returns (uint256 amount, address validator, bool active) {
        UserPurseCredit storage credit = userPurseCredits[_user][_purse];
        return (credit.amount, credit.validator, credit.active);
    }

    /**
     * @notice Get validator's default history for a user
     * @param _validator Validator address
     * @param _user User address
     * @return Total default amount
     */
    function getValidatorDefaulterHistory(
        address _validator, 
        address _user
    ) external view returns (uint256) {
        return validatorDefaulterHistory[_validator][_user];
    }

    function getUserStakedTokens(address _user) external view returns (address[] memory tokens, uint256[] memory amounts) {
        // Get whitelisted tokens
        address[] memory whitelistedTokens = tokenRegistry.getAllWhitelistedTokens();
        
        // Initialize arrays with the appropriate size
        tokens = new address[](whitelistedTokens.length);
        amounts = new uint256[](whitelistedTokens.length);
        
        // Populate arrays with user's staked tokens and amounts
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            address token = whitelistedTokens[i];
            uint256 stakedAmount = userTokenStakes[_user][token].amount;
            
            tokens[i] = token;
            amounts[i] = stakedAmount;
        }
        
        return (tokens, amounts);
    }

    /**
     * @notice Get a user's stake for a specific token
     * @param _user User address
     * @param _token Token address
     * @return amount The amount of tokens staked
     * @return timestamp The timestamp when the tokens were staked
     * @return creditsIssued The amount of credits issued for the stake
     * @return token The token address
     */
    function getUserTokenStakeInfo(address _user, address _token) external view returns (
        uint256 amount,
        uint256 timestamp,
        uint256 creditsIssued,
        address token
    ) {
        UserTokenStake storage stake = userTokenStakes[_user][_token];
        return (stake.amount, stake.timestamp, stake.creditsIssued, stake.token);
    }
} 