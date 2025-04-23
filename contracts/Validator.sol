// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./access/Roles.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidator.sol";

/**
 * @title Validator Contract
 * @notice Manages user validation and stake handling for the credit system
 * @dev Validators stake tokens to validate users and handle defaulter penalties
 */
contract Validator is AccessControl, ReentrancyGuard {
    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
    }

    // Define ValidationData struct locally in the Validator contract
    struct ValidationData {
        bool isValidated;
        uint256 creditAmount;
    }

    ValidatorData public data;
    mapping(address => ValidationData) public validatedUsers;
    
    event UserValidated(address indexed user);
    event UserInvalidated(address indexed user);
    event StakeReduced(uint256 amount, address indexed defaulter, string reason);
    event CreditsAssignedToUser(address indexed user, uint256 amount);
    event CreditsWithdrawnFromUser(address indexed user, uint256 amount);
    event StakeWithdrawn(uint256 amount);
    event StakeAdded(uint256 amount);
    event UserDefaulted(address indexed user, uint256 amount);

     // Add custom errors
    error UserAlreadyValidated();
    error InsufficientValidatorCredits();
    error UserNotValidated();
    error InsufficientUserCredits();
    error UserAlreadyValidatedByOther();

    ICreditSystem public immutable creditSystem;

    modifier onlyOwner() {
        require(msg.sender == data.owner, "Not owner");
        _;
    }

    constructor(
        uint256 _feePercentage,
        address _stakedToken,
        address _owner,
        address _creditSystem
    ) {
        data = ValidatorData({
            owner: _owner,
            feePercentage: _feePercentage,
            stakedToken: _stakedToken
        });

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        creditSystem = ICreditSystem(_creditSystem);
    }

    function validateUser(address _user, uint256 _creditAmount) external onlyOwner {
        require(!validatedUsers[_user].isValidated, "User already validated");
        
        // Calculate fee amount (feePercentage is in basis points)
        uint256 feeAmount = (_creditAmount * data.feePercentage) / 10000;
        uint256 actualCreditAmount = _creditAmount - feeAmount;
        
        // Ensure validator has enough credits
        require(creditSystem.userCredits(data.owner) >= _creditAmount, "Insufficient validator credits");
        
        // Reduce validator's credits
        creditSystem.reduceCredits(data.owner, actualCreditAmount);
        
        // Assign credits to user (minus fee)
        creditSystem.assignCredits(_user, actualCreditAmount);
        
    
        
        // Record validation
        validatedUsers[_user] = ValidationData({
            isValidated: true,
            creditAmount: _creditAmount
        });
        
        // Set validator relationship in credit system
        creditSystem.setUserValidator(_user, address(this));
        
        emit UserValidated(_user);
        emit CreditsAssignedToUser(_user, _creditAmount);
    }

    function invalidateUser(address _user) external onlyOwner {
        if (!validatedUsers[_user].isValidated) revert UserNotValidated();
        
        // Get the original credit amount assigned to this user
        uint256 originalCreditAmount = validatedUsers[_user].creditAmount;
        
        // Get current credit amount for the user
        uint256 currentCredits = creditSystem.userCredits(_user);
        
        // Reduce user credits and give them back to the validator
        if (currentCredits > 0) {
            // Reduce user credits up to the originally assigned amount
            uint256 amountToReduce = originalCreditAmount > currentCredits ? currentCredits : originalCreditAmount;
            creditSystem.reduceCredits(_user, amountToReduce);
            
            // Assign credits back to validator
            creditSystem.assignCredits(data.owner, amountToReduce);
        }
        
        // Check for default situation (user has less credits than originally assigned)
        if (currentCredits < originalCreditAmount) {
            // Calculate the default amount (what we couldn't recover)
            uint256 defaultAmount = originalCreditAmount - (currentCredits > 0 ? currentCredits : 0);
            
            // Update defaulter history via credit system
            creditSystem.updateValidatorDefaulterHistory(address(this), _user, defaultAmount);
            
            // Emit an event for the default
            emit UserDefaulted(_user, defaultAmount);
        }
        
        // Clear validator relationship
        creditSystem.setUserValidator(_user, address(0));
        
        validatedUsers[_user].isValidated = false;
        validatedUsers[_user].creditAmount = 0;
        emit UserInvalidated(_user);
    }

    function isUserValidated(address _user) external view returns (bool) {
        return validatedUsers[_user].isValidated;
    }

    function getStakedToken() external view returns (address) {
        return data.stakedToken;
    }

    /**
     * @notice Handles penalty when a user defaults on their contribution
     * @param defaulter Address of the defaulting user
     * @param recipient Address that should have received the contribution
     * @param amount Amount that was defaulted on
     */
    function handleDefaulterPenalty(
        address defaulter,
        address recipient,
        uint256 amount
    ) external {
        require(msg.sender == address(creditSystem), "Only credit system");
        
        // Only reduce stake if defaulter is not the recipient
        if (defaulter != recipient) {
            // Use the existing reduceStake function
            reduceStake(amount, recipient, "User default");
        }
    }

    /**
     * @notice Get data about this validator
     * @return ValidatorData struct with validator information
     */
    function getValidatorData() external view returns (ValidatorData memory) {
        return data;
    }

    /**
     * @notice Allows the validator owner to withdraw some of their staked tokens
     * @param _amount Amount of tokens to withdraw
     */
    function withdrawStake(uint256 _amount) external onlyOwner {
        // Check if validator has enough credits
        uint256 validatorCredits = creditSystem.userCredits(data.owner);
        if (validatorCredits < _amount) revert InsufficientValidatorCredits();
        
        // Reduce validator credits
        creditSystem.reduceCredits(data.owner, _amount);
        
        // Transfer tokens to owner
        IERC20(data.stakedToken).transfer(data.owner, _amount);
        
        emit StakeWithdrawn(_amount);
    }

    /**
     * @notice Allows the validator owner to add more stake
     * @param _amount Amount of tokens to add to stake
     */
    function addStake(uint256 _amount) external onlyOwner {
        // Transfer tokens from owner to validator contract
        IERC20(data.stakedToken).transferFrom(data.owner, address(this), _amount);
        
        // Increase validator credits
        creditSystem.assignCredits(data.owner, _amount);
        
        emit StakeAdded(_amount);
    }

    function reduceStake(uint256 _amount, address _recipient, string memory _reason) internal {
        // Check if the validator contract has enough tokens
        uint256 tokenBalance = IERC20(data.stakedToken).balanceOf(address(this));
        require(_amount <= tokenBalance, "Amount exceeds token balance");
        
        // Transfer tokens to recipient
        bool success = IERC20(data.stakedToken).transfer(_recipient, _amount);
        require(success, "Token transfer failed");
        
        emit StakeReduced(_amount, _recipient, _reason);
    }
} 