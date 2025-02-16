// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PurseContract {
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

    uint256 public constant MAX_DEFAULTERS_PER_BATCH = 5;
    uint256 public defaulterProcessingIndex;
    bool public isProcessingDefaulters;

    modifier onlyMember() {
        require(members[msg.sender].hasJoined, "Not a member");
        _;
    }

    modifier inState(PurseState _state) {
        require(purse.state == _state, "Invalid purse state");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == purse.admin, "Only admin can call");
        _;
    }

    constructor(
        address _admin,
        uint256 _contribution_amount,
        uint256 _max_members,
        uint256 _round_interval,
        address _token_address,
        uint8 _position,
        address _creditSystem,
        address _validatorFactory,
        uint256 _maxDelayTime
    ) {
        require(_position > 0 && _position <= _max_members, "Invalid position");
        require(_round_interval > 0, "Invalid interval");
        require(_contribution_amount > 0, "Invalid contribution amount");
        
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
    }

    function joinPurse(uint8 _position, address _validator) external inState(PurseState.Open) {
        require(!members[msg.sender].hasJoined, "Already a member");
        require(_position > 0 && _position <= purse.maxMembers, "Invalid position");
        require(positionToMember[_position] == address(0), "Position taken");
        require(memberList.length < purse.maxMembers, "Purse full");
        require(creditSystem.userCredits(msg.sender) >= purse.requiredCredits, "Insufficient credits");
        
        require(_validator != address(0), "Validator required");
        address validatorContract = validatorFactory.getValidatorContract(_validator);
        require(validatorContract != address(0), "Invalid validator");
        
        // Check if validator's staked token matches purse token
        address validatorStakedToken = IValidator(validatorContract).getStakedToken();
        require(validatorStakedToken == purse.tokenAddress, "Validator token mismatch");
        
        // Check if validator is active
        IValidator.ValidatorData memory validatorData = IValidator(validatorContract).data();
        require(validatorData.isActive, "Validator not eligible");
        
        // Check if user is validated by the validator
        require(IValidator(validatorContract).isUserValidated(msg.sender), "User not validated by validator");

        members[msg.sender] = Member({
            hasJoined: true,
            position: _position,
            hasContributedCurrentRound: false,
            hasReceivedPayout: false,
            totalContributed: 0,
            lastContributionTime: 0,
            validator: validatorContract
        });

        memberList.push(msg.sender);
        positionToMember[_position] = msg.sender;

        if (memberList.length == purse.maxMembers) {
            purse.state = PurseState.Active;
            purse.lastContributionTime = block.timestamp;
            emit PurseStateChanged(PurseState.Active);
        }

        emit MemberJoined(msg.sender, _position);
    }

    function contribute() external onlyMember inState(PurseState.Active) {
        Member storage member = members[msg.sender];
        require(!member.hasContributedCurrentRound, "Already contributed this round");
        require(block.timestamp >= purse.lastContributionTime, "Too early for contribution");

        token.safeTransferFrom(msg.sender, address(this), purse.contributionAmount);
        
        member.hasContributedCurrentRound = true;
        member.totalContributed += purse.contributionAmount;
        member.lastContributionTime = block.timestamp;
        purse.totalContributions += purse.contributionAmount;

        emit ContributionMade(msg.sender, purse.contributionAmount, purse.currentRound);

        // Check if all members have contributed
        if (purse.totalContributions == purse.contributionAmount * purse.maxMembers) {
            distributePayout();
        }
    }

    function distributePayout() internal {
        address payoutMember = positionToMember[purse.currentRound];
        require(payoutMember != address(0), "Invalid payout position");

        uint256 totalPayout = purse.totalContributions;
        purse.totalContributions = 0;
        
        // Send remaining payout
        if (totalPayout > 0) {
            token.safeTransfer(payoutMember, totalPayout);
        }

        emit PayoutDistributed(payoutMember, totalPayout, purse.currentRound);
        emit RoundCompleted(purse.currentRound);

        // Update round
        if (purse.currentRound == purse.maxMembers) {
            purse.state = PurseState.Completed;
            emit PurseStateChanged(PurseState.Completed);
        } else {
            purse.currentRound++;
            purse.lastContributionTime = block.timestamp;
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

    function startResolveRound() external onlyAdmin inState(PurseState.Active) {
        require(
            block.timestamp >= purse.lastContributionTime + purse.maxDelayTime,
            "Delay time not exceeded"
        );
        require(!isProcessingDefaulters, "Already processing defaulters");

        isProcessingDefaulters = true;
        defaulterProcessingIndex = 0;
        emit RoundResolutionStarted(purse.currentRound);
    }

    function processDefaultersBatch() external onlyAdmin {
        require(isProcessingDefaulters, "Resolution not started");
        
        uint256 batchEnd = Math.min(
            defaulterProcessingIndex + MAX_DEFAULTERS_PER_BATCH,
            memberList.length
        );

        address recipient = positionToMember[purse.currentRound];
        uint256 processedCount = 0;  // Add counter for processed defaulters

        for (uint256 i = defaulterProcessingIndex; i < batchEnd; i++) {
            address memberAddress = memberList[i];
            Member storage member = members[memberAddress];
            
            if (!member.hasContributedCurrentRound) {
                // Get member's validator
                address validator = member.validator;
                require(validator != address(0), "No validator found");

                // Reduce user's credits and validator stake
                creditSystem.reduceCreditsForDefault(
                    memberAddress,
                    recipient,
                    purse.contributionAmount,
                    validator
                );
                processedCount++;  // Increment counter when defaulter is processed
            }
        }

        defaulterProcessingIndex = batchEnd;
        
        emit BatchProcessed(processedCount, defaulterProcessingIndex, memberList.length);

        if (defaulterProcessingIndex >= memberList.length) {
            finalizeRoundResolution();
        }
    }

    function finalizeRoundResolution() internal {
        require(isProcessingDefaulters, "Resolution not started");
        
        // Distribute payout if there are any contributions
        if (purse.totalContributions > 0) {
            distributePayout();
        }
        
        // Reset processing state
        isProcessingDefaulters = false;
        defaulterProcessingIndex = 0;
        
        emit RoundResolutionCompleted(purse.currentRound);
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
