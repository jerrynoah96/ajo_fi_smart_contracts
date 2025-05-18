// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;
import "./purse.sol";
import "./interfaces/ICreditSystem.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./access/Roles.sol";
import "./interfaces/IValidatorFactory.sol";

/**
 * @title Purse Factory
 * @notice Factory contract for creating and tracking purse contracts
 * @dev Manages purse deployment and registration with credit system
 */
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

    function createPurse(
        uint256 _contribution_amount,
        uint256 _max_members,
        uint256 _round_interval,
        address _token_address,
        uint256 _position,
        uint256 _maxDelayTime,
        address _validator  // Optional: address(0) if no validator
    ) external returns (address purseAddress) {
        // Ensure that the creator has enough credits
        uint256 _required_credits = _contribution_amount * (_max_members - 1);
        require(creditSystem.userCredits(msg.sender) >= _required_credits, "Insufficient credits");

        // Deploy a new PurseContract
        PurseContract newPurse = new PurseContract(
            msg.sender,
            _contribution_amount,
            _max_members,
            _round_interval,
            _token_address,
            _position,
            address(creditSystem),
            address(validatorFactory),
            _maxDelayTime
        );

        // Register the purse with the credit system
        creditSystem.registerPurse(address(newPurse));

        // Add the purse to the list
        _list_of_purses.push(address(newPurse));
        purse_count++;
        id_to_purse[address(newPurse)] = purse_count;
        purseToChatId[address(newPurse)] = 0; // Assuming chatId is set to 0 for this function

        // Commit the creator's credits to the purse (crucial security step)
        creditSystem.commitCreditsToPurse(
            msg.sender,
            address(newPurse),
            _contribution_amount,
            _validator
        );

        emit PurseCreated(address(newPurse), msg.sender);
        return address(newPurse);
    }

    function allPurse() public view returns (address[] memory) {
        return _list_of_purses;
    }
}
