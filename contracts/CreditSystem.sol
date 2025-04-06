// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./access/Roles.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/ITokenRegistry.sol";

/**
 * @title Credit System
 * @notice Core contract managing credit allocation and validator relationships
 * @dev Handles credit assignment, reduction, and purse interactions
 */
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
    event ValidatorFactorySet(address indexed factory);
    event FactoryAuthorized(address indexed factory);
    event FactoryDeauthorized(address indexed factory);

    // Custom errors
    error NotAuthorizedPurse();
    error NoValidatorForUser();
    error InsufficientCommittedCredits();

    /**
     * @notice Constructor initializes the credit system with validator factory and token registry
     * @param _validatorFactory Address of the validator factory contract
     * @param _tokenRegistry Address of the token registry contract
     */
    constructor(
        address _validatorFactory,
        address _tokenRegistry
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        validatorFactory = IValidatorFactory(_validatorFactory);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
    }

    /**
     * @notice Allows users to stake tokens to receive credits
     * @param _token Address of the token to stake
     * @param _amount Amount of tokens to stake
     */
    function stakeToken(address _token, uint256 _amount) external nonReentrant {
        require(tokenRegistry.isTokenWhitelisted(_token), "Token not whitelisted");
        require(_amount > 0, "Amount must be greater than 0");
        
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        
        uint256 creditAmount = _amount;
        userCredits[msg.sender] += creditAmount;
        
        // Get existing stake if any
        UserTokenStake storage existingStake = userTokenStakes[msg.sender][_token];
        
        if (existingStake.amount > 0) {
            // Update existing stake
            existingStake.amount += _amount;
            existingStake.creditsIssued += creditAmount;
            existingStake.timestamp = block.timestamp;  
        } else {
            // Create new stake
            userTokenStakes[msg.sender][_token] = UserTokenStake({
                amount: _amount,
                timestamp: block.timestamp,
                creditsIssued: creditAmount,
                token: _token
            });
        }
        
        emit TokenStaked(msg.sender, _token, _amount, creditAmount);
    }

    /**
     * @notice Allows users to unstake their tokens and burn credits
     * @param _token Address of the token to unstake
     * @param _amount Amount of tokens to unstake (0 for all)
     */
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

        uint256 creditsToReduce = _amount;
        
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

    /**
     * @notice Assigns credits to a user
     * @param _user Address of the user to receive credits
     * @param _amount Amount of credits to assign
     */
    function assignCredits(address _user, uint256 _amount) external {
        // Check if caller is authorized
        bool isAuthorized = 
            authorizedFactories[msg.sender] || 
            authorizedPurses[msg.sender]; 
        
        require(isAuthorized, "Not authorized");
        
        userCredits[_user] += _amount;
        emit CreditsAssigned(msg.sender, _user, _amount);
    }

    /**
     * @notice Reduces credits from a user's balance
     * @param _user Address of the user
     * @param _amount Amount of credits to reduce
     */
    function reduceCredits(address _user, uint256 _amount) external {
        // Check if caller is authorized
        bool isAuthorized = 
            authorizedFactories[msg.sender] || 
            authorizedPurses[msg.sender]; // Purse contract
        
        require(isAuthorized, "Not authorized");
        require(userCredits[_user] >= _amount, "Insufficient credits");
        
        userCredits[_user] -= _amount;
        emit CreditsReduced(_user, _amount, "Manual reduction");
    }


    function registerPurse(address _purse) external {
        require(authorizedFactories[msg.sender], "Not authorized factory");
        authorizedPurses[_purse] = true;
    }

    function authorizeFactory(address _factory, bool _isValidatorFactory) external onlyRole(Roles.ADMIN_ROLE) {
        authorizedFactories[_factory] = true;
        
         if (_isValidatorFactory) {
            require(_factory != address(0), "Invalid factory address");
            validatorFactory = IValidatorFactory(_factory);
            emit ValidatorFactorySet(_factory);
        }
        
        emit FactoryAuthorized(_factory);
    }

    function deauthorizeFactory(address _factory) external onlyRole(Roles.ADMIN_ROLE) {
        authorizedFactories[_factory] = false;
        
        // If this was the validator factory, clear it
        if (address(validatorFactory) == _factory) {
            validatorFactory = IValidatorFactory(address(0));
            emit ValidatorFactorySet(address(0));
        }
        
        emit FactoryDeauthorized(_factory);
    }

   
    function setUserValidator(address _user, address _validator) external {
        // Check if validator factory is authorized
        require(authorizedFactories[address(validatorFactory)], "Validator factory not authorized");
        
        require(
            authorizedFactories[msg.sender] || 
            hasRole(Roles.ADMIN_ROLE, msg.sender) ||
            validatorFactory.getValidatorContract(msg.sender) != address(0),
            "Not authorized"
        ); 

        // Allow address(0) specifically for clearing validators
        if (_validator != address(0)) {
            bool isValidatorContract = validatorFactory.isValidatorContract(_validator);
            require(isValidatorContract == true, "Not a validator contract");
        }
       
        // If user already has a validator...
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
        require(validatorFactory.isValidatorContract(msg.sender), "Only validator contracts");
        
        // Find which validator owner controls this validator contract
        address callerAsValidator;
        address[] memory activeValidators = validatorFactory.getActiveValidators();
        for (uint i = 0; i < activeValidators.length; i++) {
            if (validatorFactory.getValidatorContract(activeValidators[i]) == msg.sender) {
                callerAsValidator = activeValidators[i];
                break;
            }
        }
        
        require(
            _from == callerAsValidator || // Validator transferring their own credits
            userValidators[_from] == callerAsValidator, // User validated by this validator
            "Not validated by this validator"
        );
        
        require(userCredits[_from] >= _amount, "Insufficient credits");
        
        userCredits[_from] -= _amount;
        userCredits[_to] += _amount;
        
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
            authorizedPurses[msg.sender],
            "Not authorized"
        );
        
        // Ensure user has enough credits
        require(userCredits[_user] >= _amount, "Insufficient credits");
        
        // Validate the validator if provided
        if (_validator != address(0)) {
            // Check if this is a valid validator contract
            bool isValidatorContract = validatorFactory.isValidatorContract(_validator);
            require(isValidatorContract == true, "Invalid validator");
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
     * @param _recipient Address to receive slashed tokens
     */
    function handleUserDefault(
        address _user,
        address _purse,
        uint256 _amount,
        address _recipient
    ) external {
        // Check that caller is an authorized purse
        if (!authorizedPurses[_purse]) revert NotAuthorizedPurse();
        
        // Get the validator owner for this user's credit
        address validatorContract = userPurseCredits[_user][_purse].validator;
        if (validatorContract == address(0)) revert NoValidatorForUser();
        
        
        // Get available user credits for this purse
        uint256 committedCredits = userPurseCredits[_user][_purse].amount;
        if (committedCredits < _amount) revert InsufficientCommittedCredits();
        
        // Call the validator's handleDefaulterPenalty function
        try IValidator(validatorContract).handleDefaulterPenalty(_user, _recipient, _amount) {
            // Only reduce credits and mark as processed if penalty succeeds
            userPurseCredits[_user][_purse].amount -= _amount;
            
            if (userPurseCredits[_user][_purse].amount == 0) {
                userPurseCredits[_user][_purse].active = false;
            }
            
            validatorDefaulterHistory[validatorContract][_user] += _amount;
            emit DefaulterPenaltyApplied(_user, validatorContract, _amount);
        } catch (bytes memory reason) {
            emit DefaulterPenaltyFailed(_user, validatorContract, _amount, reason);
            revert("Penalty application failed");
        }
    }

    /**
     * @notice Release committed credits after purse round completes
     * @param _user User address
     * @param _purse Purse address
     */
    function releasePurseCredits(address _user, address _purse) external  {
        require(
            authorizedPurses[msg.sender],
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