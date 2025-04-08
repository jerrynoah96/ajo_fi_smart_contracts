// contracts/ValidatorFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidator.sol";
import "./interfaces/ITokenRegistry.sol";
import "./Validator.sol";
import "./access/Roles.sol";

/**
 * @title Validator Factory
 * @notice Factory contract for deploying and managing validators
 * @dev Handles validator creation, configuration, and tracking
 */
contract ValidatorFactory is AccessControl, ReentrancyGuard {
    ICreditSystem public creditSystem;
    ITokenRegistry public tokenRegistry;
    
    struct ValidatorConfig {
        uint256 minStakeAmount;      // Minimum amount validator must stake
        uint256 maxFeePercentage;    // Maximum fee validator can charge (in basis points)
    }

    ValidatorConfig public config;
    mapping(address => address) public validatorContracts; // validator address => validator contract
    address[] public validatorList;

    event ValidatorCreated(
        address indexed validator,
        address indexed validatorContract,
        uint256 stakedAmount,
        uint256 feePercentage
    );
    event ValidatorConfigUpdated(
        uint256 minStakeAmount,
        uint256 maxFeePercentage
    );
    event ValidatorParameterUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event ValidatorCredited(address indexed validator, uint256 amount);
    event CreditSystemUpdated(address indexed oldSystem, address indexed newSystem);
    event TokenRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);


    error AlreadyRegistered();
    error FeeTooHigh();
    error InsufficientStake();
    error TokenNotWhitelisted();
    error InvalidCreditSystem();
    error InvalidParameter();

    /**
     * @notice Contract constructor
     * @param _creditSystem Address of the credit system contract
     * @param _minStakeAmount Minimum stake amount required for validators
     * @param _maxFeePercentage Maximum fee percentage validators can charge
     * @param _tokenRegistry Address of the token registry contract
     */
    constructor(
        address _creditSystem,
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage,
        address _tokenRegistry
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        
        creditSystem = ICreditSystem(_creditSystem);
        tokenRegistry = ITokenRegistry(_tokenRegistry);
        
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });
    }

    /**
     * @notice Create a new validator
     * @param _feePercentage The fee percentage charged by the validator
     * @param _tokenToStake The token address to stake
     * @param _stakeAmount The amount to stake
     */
    function createValidator(
        uint256 _feePercentage, 
        address _tokenToStake, 
        uint256 _stakeAmount
    ) external nonReentrant {
        if (validatorContracts[msg.sender] != address(0)) revert AlreadyRegistered();
        if (_feePercentage > config.maxFeePercentage) revert FeeTooHigh();
        if (_stakeAmount < config.minStakeAmount) revert InsufficientStake();
        if (IERC20(_tokenToStake).balanceOf(msg.sender) < _stakeAmount) revert InsufficientStake();
        if (!tokenRegistry.isTokenWhitelisted(_tokenToStake)) revert TokenNotWhitelisted();

        // Deploy new validator contract with updated constructor parameters
        Validator validator = new Validator(
            _feePercentage,
            _tokenToStake,
            msg.sender,
            address(creditSystem)
        );

        // Transfer stake - using the custom amount, not just the minimum
        IERC20(_tokenToStake).transferFrom(msg.sender, address(validator), _stakeAmount);
        
        // Assign credits to validator with 1:1 ratio (100% of stake as credits)
        uint256 creditAmount = _stakeAmount; // 1:1 ratio for the full custom stake
        creditSystem.assignCredits(msg.sender, creditAmount);

        validatorContracts[msg.sender] = address(validator);
        validatorList.push(msg.sender);

        emit ValidatorCreated(
            msg.sender,
            address(validator),
            _stakeAmount,
            _feePercentage
        );
        emit ValidatorCredited(msg.sender, creditAmount);
    }

    /**
     * @notice Get the validator contract address for a validator owner
     * @param _validator The validator owner address
     * @return The validator contract address
     */
    function getValidatorContract(address _validator) external view returns (address) {
        return validatorContracts[_validator];
    }

    /**
     * @notice Get all active validators
     * @return Array of active validator owner addresses
     */
    function getActiveValidators() external view returns (address[] memory) {
        // Since we removed the isActive flag, all validators in the list are considered active
        address[] memory activeValidators = new address[](validatorList.length);
        
        for (uint256 i = 0; i < validatorList.length; i++) {
            address validatorContract = validatorContracts[validatorList[i]];
            if (validatorContract != address(0)) {
                activeValidators[i] = validatorList[i];
            }
        }
        
        return activeValidators;
    }

    /**
     * @notice Update a specific validator configuration parameter (numeric values)
     * @param _parameter Name of the parameter to update ("minStakeAmount" or "maxFeePercentage")
     * @param _value New value for the parameter
     */
    function updateValidatorParameter(string memory _parameter, uint256 _value) external onlyRole(Roles.ADMIN_ROLE) {
        bytes32 paramHash = keccak256(abi.encodePacked(_parameter));
        
        if (paramHash == keccak256(abi.encodePacked("minStakeAmount"))) {
            uint256 oldValue = config.minStakeAmount;
            config.minStakeAmount = _value;
            emit ValidatorParameterUpdated("minStakeAmount", oldValue, _value);
        } else if (paramHash == keccak256(abi.encodePacked("maxFeePercentage"))) {
            uint256 oldValue = config.maxFeePercentage;
            config.maxFeePercentage = _value;
            emit ValidatorParameterUpdated("maxFeePercentage", oldValue, _value);
        } else {
            revert InvalidParameter();
        }
        
        // Also emit the general config update event for backward compatibility
        emit ValidatorConfigUpdated(
            config.minStakeAmount,
            config.maxFeePercentage
        );
    }

    /**
     * @notice Update a specific validator address parameter
     * @param _parameter Name of the parameter to update ("creditSystem" or "tokenRegistry")
     * @param _value New address value for the parameter
     */
    function updateAddressParameter(string memory _parameter, address _value) external onlyRole(Roles.ADMIN_ROLE) {
        bytes32 paramHash = keccak256(abi.encodePacked(_parameter));
        
        if (paramHash == keccak256(abi.encodePacked("creditSystem"))) {
            if (_value == address(0)) revert InvalidCreditSystem();
            address oldSystem = address(creditSystem);
            creditSystem = ICreditSystem(_value);
            emit CreditSystemUpdated(oldSystem, _value);
        } else if (paramHash == keccak256(abi.encodePacked("tokenRegistry"))) {
            if (_value == address(0)) revert InvalidParameter();
            address oldRegistry = address(tokenRegistry);
            tokenRegistry = ITokenRegistry(_value);
            emit TokenRegistryUpdated(oldRegistry, _value);
        } else {
            revert InvalidParameter();
        }
    }

    /**
     * @notice Update all configuration parameters at once
     * @param _minStakeAmount New minimum stake amount
     * @param _maxFeePercentage New maximum fee percentage
     */
    function updateAllConfig(
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage
    ) external onlyRole(Roles.ADMIN_ROLE) {
        uint256 oldMinStake = config.minStakeAmount;
        uint256 oldMaxFee = config.maxFeePercentage;
        
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });

        emit ValidatorParameterUpdated("minStakeAmount", oldMinStake, _minStakeAmount);
        emit ValidatorParameterUpdated("maxFeePercentage", oldMaxFee, _maxFeePercentage);
        
        emit ValidatorConfigUpdated(
            _minStakeAmount,
            _maxFeePercentage
        );
    }

    /**
     * @notice Check if an address is a validator contract deployed by this factory
     * @param _contract The address to check
     * @return Whether the address is a validator contract
     */
    function isValidatorContract(address _contract) external view returns (bool) {
        // Check if this contract is in our list of deployed validators
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorContracts[validatorList[i]] == _contract) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get the owner of a validator contract
     * @param _validatorContract The validator contract address
     * @return The validator owner address
     */
    function getValidatorOwner(address _validatorContract) external view returns (address) {
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorContracts[validatorList[i]] == _validatorContract) {
                return validatorList[i];
            }
        }
        return address(0);
    }
}