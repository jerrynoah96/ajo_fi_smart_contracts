// contracts/ValidatorFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidator.sol";
import "./Validator.sol";
import "./access/Roles.sol";

contract ValidatorFactory is AccessControl, ReentrancyGuard {
    struct ValidatorConfig {
        uint256 minStakeAmount;      // Minimum amount validator must stake
        uint256 maxFeePercentage;    // Maximum fee validator can charge (in basis points)
    }

    ICreditSystem public creditSystem;
    
    ValidatorConfig public config;
    mapping(address => address) public validatorContracts; // validator address => validator contract
    address[] public validatorList;
    mapping(address => bool) public whitelistedTokens;

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
    event ValidatorCredited(address indexed validator, uint256 amount);
    event TokenWhitelisted(address indexed token, bool status);
    event CreditSystemUpdated(address indexed oldSystem, address indexed newSystem);

    constructor(
        address _creditSystem,
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage,
        address _defaultToken
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        
        creditSystem = ICreditSystem(_creditSystem);
        
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });
        
        // Whitelist default token
        if (_defaultToken != address(0)) {
            whitelistedTokens[_defaultToken] = true;
            emit TokenWhitelisted(_defaultToken, true);
        }
    }

    function createValidator(
        uint256 _feePercentage, 
        address _tokenToStake, 
        uint256 _stakeAmount
    ) external nonReentrant {
        if (validatorContracts[msg.sender] != address(0)) revert AlreadyRegistered();
        if (_feePercentage > config.maxFeePercentage) revert FeeTooHigh();
        if (_stakeAmount < config.minStakeAmount) revert InsufficientStake();
        if (IERC20(_tokenToStake).balanceOf(msg.sender) < _stakeAmount) revert InsufficientStake();
        if (!whitelistedTokens[_tokenToStake]) revert TokenNotWhitelisted();

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

    function getValidatorContract(address _validator) external view returns (address) {
        return validatorContracts[_validator];
    }

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

    function updateConfig(
        uint256 _minStakeAmount,
        uint256 _maxFeePercentage
    ) external onlyRole(Roles.ADMIN_ROLE) {
        config = ValidatorConfig({
            minStakeAmount: _minStakeAmount,
            maxFeePercentage: _maxFeePercentage
        });

        emit ValidatorConfigUpdated(
            _minStakeAmount,
            _maxFeePercentage
        );
    }

    function setTokenWhitelist(address _token, bool _status) external onlyRole(Roles.ADMIN_ROLE) {
        whitelistedTokens[_token] = _status;
        emit TokenWhitelisted(_token, _status);
    }

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
     * @notice Update the credit system address
     * @param _creditSystem The new credit system address
     */
    function updateCreditSystem(address _creditSystem) external onlyRole(Roles.ADMIN_ROLE) {
        require(_creditSystem != address(0), "Invalid credit system");
        address oldSystem = address(creditSystem);
        creditSystem = ICreditSystem(_creditSystem);
        emit CreditSystemUpdated(oldSystem, _creditSystem);
    }

    error AlreadyRegistered();
    error FeeTooHigh();
    error InsufficientStake();
    error TokenNotWhitelisted();
}