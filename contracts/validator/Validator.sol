// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '../access/Roles.sol';
import '../interfaces/ICreditSystem.sol';

error NotOwner();
error ValidatorNotActive();
error UserAlreadyValidated();
error UserNotValidated();
error OnlyCreditSystem();
error InsufficientStake();

contract Validator is AccessControl, ReentrancyGuard {
    uint256 public constant MIN_STAKE_AMOUNT = 1000 ether; // Should match ValidatorFactory config

    struct ValidatorData {
        address owner;
        uint256 feePercentage;
        address stakedToken;
        uint256 stakedAmount;
        bool isActive;
    }

    ValidatorData public data;
    mapping(address => bool) public validatedUsers;

    event UserValidated(address indexed user);
    event UserInvalidated(address indexed user);
    event StakeReduced(uint256 amount, string reason);

    ICreditSystem public immutable creditSystem;

    modifier onlyOwner() {
        if (msg.sender != data.owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 _stakedAmount,
        uint256 _feePercentage,
        address _stakedToken,
        address _owner,
        address _creditSystem
    ) {
        data = ValidatorData({
            owner: _owner,
            feePercentage: _feePercentage,
            stakedToken: _stakedToken,
            stakedAmount: _stakedAmount,
            isActive: true
        });

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        creditSystem = ICreditSystem(_creditSystem);
    }

    function validateUser(address _user) external onlyOwner {
        if (!data.isActive) revert ValidatorNotActive();
        if (validatedUsers[_user]) revert UserAlreadyValidated();

        validatedUsers[_user] = true;
        emit UserValidated(_user);
    }

    function invalidateUser(address _user) external onlyOwner {
        if (!validatedUsers[_user]) revert UserNotValidated();

        validatedUsers[_user] = false;
        emit UserInvalidated(_user);
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
        if (msg.sender != address(creditSystem)) revert OnlyCreditSystem();
        if (!data.isActive) revert ValidatorNotActive();

        // Only reduce stake if defaulter is not the recipient
        if (defaulter != recipient) {
            if (data.stakedAmount < amount) revert InsufficientStake();

            // Reduce stake amount
            data.stakedAmount -= amount;

            // Transfer penalty amount to recipient
            IERC20(data.stakedToken).transfer(recipient, amount);

            emit StakeReduced(amount, 'User default');

            // If stake falls below minimum, deactivate validator
            if (data.stakedAmount < MIN_STAKE_AMOUNT) {
                data.isActive = false;
            }
        }
    }

    function getValidatorData() external view returns (ValidatorData memory) {
        return data;
    }
}