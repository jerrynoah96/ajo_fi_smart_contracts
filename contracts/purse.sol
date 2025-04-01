// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PurseContract is AccessControl {
    using SafeERC20 for IERC20;

    enum PurseState {
        Open,      // Initial state, accepting members
        Active,    // All members joined, contributions started
        Completed, // All rounds completed
        Terminated // Emergency stop
    }

    struct Purse {
        PurseState state;
        uint256 contributionAmount;    // Amount each member contributes per round
        uint256 totalContributions;    // Total contributions in current round
        uint256 roundInterval;         // Time between rounds
        uint256 lastContributionTime;  // Timestamp of last contribution round
        uint256 currentRound;          // Current round number (1-based)
        uint256 maxMembers;            // Maximum number of members
        uint256 requiredCredits;       // Credits required to join
        address tokenAddress;          // ERC20 token used for contributions
        uint256 maxDelayTime;         // Maximum allowed delay time before admin intervention
        address admin;                // Admin address (usually the creator)
    }

    // Member struct to track individual member details
    struct Member {
        bool hasJoined;
        uint256 position;              // Position in rotation (1-based)
        bool hasContributedCurrentRound;
        bool hasReceivedPayout;
        uint256 totalContributed;
        uint256 lastContributionTime;
        address validator;           // Validator who vouched for the member
    }

    Purse public purse;
    IERC20 public token;
    ICreditSystem public immutable creditSystem;
    IValidatorFactory public validatorFactory;
    
    // Add state variable to track penalties
    uint256 public defaulterPenalties;
    
    mapping(address => Member) public members;
    address[] public memberList;
    mapping(uint256 => address) public positionToMember;

    // Events
    event PurseCreated(address indexed creator, uint256 contributionAmount, uint256 maxMembers);
    event MemberJoined(address indexed member, uint256 position);
    event ContributionMade(address indexed member, uint256 amount, uint256 round);
    event PayoutDistributed(address indexed member, uint256 amount, uint256 round);
    event PurseStateChanged(PurseState newState);
    event RoundCompleted(uint256 round);
    event RoundResolutionStarted(uint256 round);
    event BatchProcessed(uint256 processedCount, uint256 currentIndex, uint256 totalMembers);
    event RoundResolutionCompleted(uint256 round);
    event DefaulterProcessingFailed(address indexed member, bytes reason);
    event DefaulterProcessed(address indexed member, uint256 amount);

    uint256 public constant MAX_DEFAULTERS_PER_BATCH = 5;
    uint256 public defaulterProcessingIndex;
    bool public isProcessingDefaulters;

    // Define custom errors at the contract level
    error AlreadyMember();
    error InvalidPosition();
    error PositionTaken();
    error PurseFull();
    error InsufficientCredits();
    error ValidatorRequired();
    error InvalidValidator();
    error ValidatorNotEligible();
    error UserNotValidated();
    error InvalidPurseState(PurseState required, PurseState current);
    error NotMember();
    error DelayTimeNotExceeded();
    error AlreadyProcessingDefaulters();
    error ResolutionNotStarted();
    error AlreadyContributed();
    error TooEarlyForContribution();
    error AlreadyReceivedPayout();
    error OnlyAdminCanCall();
    error InvalidInterval();
    error InvalidContributionAmount();

    // Store the admin's position
    uint256 public adminPosition;

    modifier onlyMember() {
        if (!members[msg.sender].hasJoined) revert NotMember();
        _;
    }

    modifier inState(PurseState _state) {
        if (purse.state != _state) revert InvalidPurseState(_state, purse.state);
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != purse.admin) revert OnlyAdminCanCall();
        _;
    }

    constructor(
        address _admin,
        uint256 _contribution_amount,
        uint256 _max_members,
        uint256 _round_interval,
        address _token_address,
        uint256 _position,
        address _creditSystem,
        address _validatorFactory,
        uint256 _maxDelayTime
    ) {
        if (_position == 0 || _position > _max_members) revert InvalidPosition();
        if (_round_interval == 0) revert InvalidInterval();
        if (_contribution_amount == 0) revert InvalidContributionAmount();
        
        creditSystem = ICreditSystem(_creditSystem);
        token = IERC20(_token_address);
        validatorFactory = IValidatorFactory(_validatorFactory);

        purse = Purse({
            state: PurseState.Open,
            contributionAmount: _contribution_amount,
            totalContributions: 0,
            roundInterval: _round_interval,
            lastContributionTime: 0,
            currentRound: 1,
            maxMembers: _max_members,
            requiredCredits: _contribution_amount * (_max_members - 1),
            tokenAddress: _token_address,
            maxDelayTime: _maxDelayTime,
            admin: _admin
        });

        members[_admin] = Member({
            hasJoined: true,
            position: _position,
            hasContributedCurrentRound: false,
            hasReceivedPayout: false,
            totalContributed: 0,
            lastContributionTime: 0,
            validator: address(0)
        });

        memberList.push(_admin);
        positionToMember[_position] = _admin;

        emit PurseCreated(_admin, _contribution_amount, _max_members);
        emit MemberJoined(_admin, _position);

        // Grant admin role to creator
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        
        // Store admin position
        adminPosition = _position;
    }

    /**
     * @notice Allows a user to join the purse
     * @param _position The position in the rotation the user wants to take
     * @param _validator The validator address (can be address(0) if validators aren't required)
     */
    function joinPurse(uint256 _position, address _validator) external {
        require(_position > 0 && _position <= purse.maxMembers, "Invalid position");
        require(_position != adminPosition, "Admin position not available");
        require(positionToMember[_position] == address(0), "Position already taken");
        require(!members[msg.sender].hasJoined, "Already a member");
        
        // Verify user has a validator if provided
        if (_validator != address(0)) {
            address validatorContract = validatorFactory.getValidatorContract(_validator);
            require(validatorContract != address(0), "Invalid validator");
            
            // Check if validator has validated the user
            bool isValidated = IValidator(validatorContract).isUserValidated(msg.sender);
            require(isValidated, "Not validated by validator");
            
            // Get validator data and ensure token matches purse token
            IValidator.ValidatorData memory validatorData = IValidator(validatorContract).getValidatorData();
            require(validatorData.stakedToken == address(token), "Validator token mismatch with purse token");
        }
        else {
            // For users without validators, check if they have staked the purse token
            (uint256 stakedAmount, , , ) = creditSystem.getUserTokenStakeInfo(msg.sender, address(token));
            require(stakedAmount > 0, "Must stake purse token to join without validator");
        }
        
        // Commit user credits to this purse - this will check credit balance
        creditSystem.commitCreditsToPurse(
            msg.sender, 
            address(this), 
            purse.requiredCredits,
            _validator
        );
        
        // Add user to purse
        members[msg.sender] = Member({
            hasJoined: true,
            position: _position,
            hasContributedCurrentRound: false,
            hasReceivedPayout: false,
            totalContributed: 0,
            lastContributionTime: 0,
            validator: _validator
        });

        positionToMember[_position] = msg.sender;
        memberList.push(msg.sender);
        
        emit MemberJoined(msg.sender, _position);

        // If all positions are filled, start the purse
        if (memberList.length == purse.maxMembers) {
            purse.state = PurseState.Active;
            purse.lastContributionTime = block.timestamp;
            emit PurseStateChanged(PurseState.Active);
        }
    }

    function contribute() external onlyMember inState(PurseState.Active) {
        Member storage member = members[msg.sender];
        if (member.hasContributedCurrentRound) revert AlreadyContributed();
        if (block.timestamp < purse.lastContributionTime) revert TooEarlyForContribution();

        token.safeTransferFrom(msg.sender, address(this), purse.contributionAmount);
        
        member.hasContributedCurrentRound = true;
        member.totalContributed += purse.contributionAmount;
        member.lastContributionTime = block.timestamp;
        purse.totalContributions += purse.contributionAmount;

        emit ContributionMade(msg.sender, purse.contributionAmount, purse.currentRound);

        // Check if all members have contributed
        if (purse.totalContributions == purse.contributionAmount * purse.maxMembers) {
            _distributePayout();
        }
    }

    /**
     * @notice Distribute payout to the member whose turn it is in the current round
     */
    function _distributePayout() internal {
        // Get recipient for this round
        address recipient = positionToMember[purse.currentRound];
        require(recipient != address(0), "No recipient for this round");
        
        // Only transfer the actual contributed amounts from the purse
        // Defaulter penalties are handled separately and sent directly to recipient
        if (purse.totalContributions > 0) {
            token.safeTransfer(recipient, purse.totalContributions);
        }
        
        // Mark recipient as having received payout
        members[recipient].hasReceivedPayout = true;
        
        // Emit event with total amount distributed (contributions + default penalties)
        emit PayoutDistributed(recipient, purse.totalContributions + defaulterPenalties, purse.currentRound);
    }

    function startNewRound() internal {
            purse.currentRound++;
        purse.totalContributions = 0;
        defaulterPenalties = 0;  // Reset penalties for new round
            purse.lastContributionTime = block.timestamp;

        // Reset member states for new round
        for (uint256 i = 0; i < memberList.length; i++) {
            address memberAddr = memberList[i];
            members[memberAddr].hasContributedCurrentRound = false;
            members[memberAddr].hasReceivedPayout = false;
        }
    }

    function getCurrentRound() external view returns (
        uint256 round,
        address currentRecipient,
        uint256 totalContributions,
        uint256 nextContributionTime
    ) {
        return (
            purse.currentRound,
            positionToMember[purse.currentRound],
            purse.totalContributions,
            purse.lastContributionTime + purse.roundInterval
        );
    }

    function getMemberInfo(address _member) external view returns (
        bool hasJoined,
        uint256 position,
        bool hasContributedCurrentRound,
        bool hasReceivedPayout,
        uint256 totalContributed
    ) {
        Member memory member = members[_member];
        return (
            member.hasJoined,
            member.position,
            member.hasContributedCurrentRound,
            member.hasReceivedPayout,
            member.totalContributed
        );
    }

    function getAllMembers() external view returns (address[] memory) {
        return memberList;
    }

    // Modified to allow anyone to call and process defaulters automatically
    function startResolveRound() external inState(PurseState.Active) {
        if (block.timestamp < purse.lastContributionTime + purse.maxDelayTime) 
            revert DelayTimeNotExceeded();
        if (isProcessingDefaulters) revert AlreadyProcessingDefaulters();

        isProcessingDefaulters = true;
        defaulterProcessingIndex = 0;
        emit RoundResolutionStarted(purse.currentRound);
        
        // Process all defaulters immediately
        _processAllDefaulters();
    }

    // New function to process all defaulters at once
    function _processAllDefaulters() internal {
        address recipient = positionToMember[purse.currentRound];
        uint256 processedCount = 0;
        uint256 totalDefaultAmount = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address memberAddress = memberList[i];
            Member storage member = members[memberAddress];
            
            if (!member.hasContributedCurrentRound) {
                // Get member's validator
                address validator = member.validator;
                
                // Process defaulter
                try creditSystem.handleUserDefault(
                    memberAddress,
                    address(this),
                    purse.contributionAmount,
                    address(token),
                    recipient
                ) {
                    processedCount++;
                    totalDefaultAmount += purse.contributionAmount;
                    emit DefaulterProcessed(memberAddress, purse.contributionAmount);
                } catch (bytes memory reason) {
                    emit DefaulterProcessingFailed(memberAddress, reason);
                    continue;
                }
            }
        }

        emit BatchProcessed(processedCount, memberList.length, memberList.length);
        
        // Track total penalties processed for accounting
        defaulterPenalties = totalDefaultAmount;
        
        // Finalize round resolution
        finalizeRoundResolution();
    }


    function finalizeRoundResolution() internal {
        if (!isProcessingDefaulters) revert ResolutionNotStarted();
        
        // Distribute payout if there are any contributions
        if (purse.totalContributions > 0) {
            _distributePayout();
        }
        
        // Reset processing state
        isProcessingDefaulters = false;
        defaulterProcessingIndex = 0;
        
        emit RoundResolutionCompleted(purse.currentRound);
        
        // Start a new round after resolving the current one
        startNewRound();
    }

    function getResolutionProgress() external view returns (
        bool isProcessing,
        uint256 currentIndex,
        uint256 totalMembers,
        uint256 remainingToProcess
    ) {
        return (
            isProcessingDefaulters,
            defaulterProcessingIndex,
            memberList.length,
            memberList.length - defaulterProcessingIndex
        );
    }

}
