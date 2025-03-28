// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./access/Roles.sol";
import "./interfaces/ICreditSystem.sol";

contract Validator is AccessControl, ReentrancyGuard {
    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
    }

    ValidatorData public data;
    mapping(address => bool) public validatedUsers;
    
    event UserValidated(address indexed user);
    event UserInvalidated(address indexed user);
    event StakeReduced(uint256 amount, address indexed defaulter, string reason);
    event CreditsAssignedToUser(address indexed user, uint256 amount);
    event CreditsWithdrawnFromUser(address indexed user, uint256 amount);
    event StakeWithdrawn(uint256 amount);
    event StakeAdded(uint256 amount);

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
        if (validatedUsers[_user]) revert UserAlreadyValidated();
        
        // Check if user is already validated by another validator
        address currentValidator = creditSystem.userValidators(_user);
        if (currentValidator != address(0) && currentValidator != data.owner) 
            revert UserAlreadyValidatedByOther();
        
        // Check if validator has enough credits
        uint256 validatorCredits = creditSystem.userCredits(data.owner);
        if (validatorCredits < _creditAmount) revert InsufficientValidatorCredits();
        
        // Transfer credits from validator to user
        creditSystem.transferCredits(data.owner, _user, _creditAmount);
        
        // Set this validator as the user's validator
        creditSystem.setUserValidator(_user, data.owner);
        
        validatedUsers[_user] = true;
        emit UserValidated(_user);
        emit CreditsAssignedToUser(_user, _creditAmount);
    }

    function invalidateUser(address _user, uint256 _creditAmount) external onlyOwner {
        if (!validatedUsers[_user]) revert UserNotValidated();
        
        // Check if user has enough credits to withdraw
        uint256 userCredits = creditSystem.userCredits(_user);
        if (userCredits < _creditAmount) revert InsufficientUserCredits();
        
        // Transfer credits back from user to validator
        creditSystem.transferCredits(_user, data.owner, _creditAmount);
        
        // Clear validator relationship
        creditSystem.setUserValidator(_user, address(0));
        
        validatedUsers[_user] = false;
        emit UserInvalidated(_user);
        emit CreditsWithdrawnFromUser(_user, _creditAmount);
    }

    function isUserValidated(address _user) external view returns (bool) {
        return validatedUsers[_user];
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
            // Reduce validator credits instead of stake
            creditSystem.reduceCredits(data.owner, amount);
            
            // Transfer penalty amount to recipient
            IERC20(data.stakedToken).transfer(recipient, amount);
            
            emit StakeReduced(amount, defaulter, "User default");
        }
    }

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

    // Add custom errors
    error UserAlreadyValidated();
    error InsufficientValidatorCredits();
    error UserNotValidated();
    error InsufficientUserCredits();
    error UserAlreadyValidatedByOther();
} 