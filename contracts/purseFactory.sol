// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "./purse.sol";
import "./interfaces/ICreditSystem.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./access/Roles.sol";
import "./interfaces/IValidatorFactory.sol";

contract PurseFactory is AccessControl {
    event PurseCreated(address indexed purse, address indexed creator);

    //0xf0169620C98c21341aBaAeaFB16c69629Dafc06b
    uint256 public purse_count;
    address[] _list_of_purses; //this array contains addresss of each purse
    mapping(address => uint256) id_to_purse;
    mapping(address => uint256) public purseToChatId;
    
    ICreditSystem public immutable creditSystem;
    IValidatorFactory public immutable validatorFactory;

    constructor(address _creditSystem, address _validatorFactory) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Roles.ADMIN_ROLE, msg.sender);
        creditSystem = ICreditSystem(_creditSystem);
        validatorFactory = IValidatorFactory(_validatorFactory);
        // Make sure the PurseFactory is authorized in the CreditSystem
        // This should be done by the admin after deployment
    }

    // TODO : creator should have the needed checks for validator and should to join purse without validtor 

    function createPurse(
        uint256 contribution_amount,
        uint256 _max_member,
        uint256 time_interval,
        uint256 chatId,
        address _tokenAddress,
        uint8 _position,
        uint256 _maxDelayTime
    ) public {
        // Calculate required credits (same as collateral)
        uint256 _required_credits = contribution_amount * (_max_member - 1);
        
        // Check if user has enough credits
        require(creditSystem.userCredits(msg.sender) >= _required_credits, "Insufficient credits");

        // Reduce user's credits (this acts as collateral)
        creditSystem.reduceCredits(msg.sender, _required_credits);
        
        // Create new purse with maxDelayTime parameter
        PurseContract purse = new PurseContract(
            msg.sender,
            contribution_amount,
            _max_member,
            time_interval,
            _tokenAddress,
            _position,
            address(creditSystem),
            address(validatorFactory),
            _maxDelayTime
        );

        // Register the purse with credit system
        creditSystem.registerPurse(address(purse));

        // Add purse to tracking
        _list_of_purses.push(address(purse));
        purse_count++;
        id_to_purse[address(purse)] = purse_count;
        purseToChatId[address(purse)] = chatId;

        emit PurseCreated(address(purse), msg.sender);
    }

    function allPurse() public view returns (address[] memory) {
        return _list_of_purses;
    }
}
