// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// PUSH Comm Contract Interface
interface IPUSHCommInterface {
    function sendNotification(
        address _channel,
        address _recipient,
        bytes calldata _identity
    ) external;
}

contract VanillaWrapper is ERC20 {
    /** ============================================
                 STORAGE
================================================ */

    IERC20 asset;
    address governor;

    uint256 constant PERCENTAGE_PROFIT_IN_BIPS = 10000;

    struct DepositState {
        bool initialized;
        address altAccount;
        uint256 amount;
        uint256 conflictPeriod;
    }

    struct WithdrawRequest {
        bool isBlocked;
        uint256 initTimestamp;
        uint256 amount;
        address complainant;
    }

    mapping(address => DepositState) public deposits;
    mapping(address => WithdrawRequest) public withdrawals;

    modifier onlyGovernor() {
        require(msg.sender == governor, "Only Governor");
        _;
    }

    function setUpUser(address _altAddress, uint256 _conflictPeriod) public {
        require(!deposits[msg.sender].initialized, "user already initialized");
        deposits[msg.sender] = DepositState(
            true,
            _altAddress,
            0,
            _conflictPeriod
        );
    }

    function wrap(uint256 _amount) public {
        require(deposits[msg.sender].initialized, "user not initialized");
        deposits[msg.sender].amount += _amount;
        _mint(msg.sender, _amount);
        asset.transferFrom(msg.sender, address(this), _amount);
    }

    // initiateUnwrap can only be called if the last payment has gone through
    function initiateUnwrap(uint256 _amount) public {
        require(
            withdrawals[msg.sender].amount == 0,
            "unwrap already initialized"
        );
        require(
            _amount <= deposits[msg.sender].amount,
            "insufficient deposits"
        );
        unchecked {
            deposits[msg.sender].amount -= _amount;
        }
        withdrawals[msg.sender] = WithdrawRequest(
            false,
            block.timestamp,
            _amount,
            address(0)
        );
        _transfer(msg.sender, address(this), _amount);

        // Add EPNS notification here
    }

    function completeUnwrap() public {
        require(
            block.timestamp >=
                withdrawals[msg.sender].initTimestamp +
                    deposits[msg.sender].conflictPeriod,
            "conflict period ongoing"
        );
        require(!withdrawals[msg.sender].isBlocked, "withdrawal is blocked");
        uint256 tempAmount = withdrawals[msg.sender].amount;
        _burn(address(this), tempAmount);
        asset.transferFrom(address(this), msg.sender, tempAmount);

        IPUSHCommInterface(0xb3971BCef2D791bc4027BbfedFb47319A4AAaaAa)
            .sendNotification(
                0x668417616f1502D13EA1f9528F83072A133e8E01, // from channel - recommended to set channel via dApp and put it's value -> then once contract is deployed, go back and add the contract address as delegate for your channel
                msg.sender, // to recipient, put address(this) in case you want Broadcast or Subset. For Targetted put the address to which you want to send
                bytes(
                    string(
                        abi.encodePacked(
                            "0", // this is notification identity: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/identity/payload-identity-implementations
                            "+", // segregator
                            "3", // this is payload type: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/payload (1, 3 or 4) = (Broadcast, targetted or subset)
                            "+", // segregator
                            "Transfer", // this is notificaiton title
                            "+", // segregator
                            abi.encodePacked(tempAmount, " from", address(this)) // notification body
                        )
                    )
                )
            );
    }

    function lodgeConflict(address _withdrawalAddress) public {
        require(
            !withdrawals[_withdrawalAddress].isBlocked,
            "conflict already lodged"
        );
        withdrawals[_withdrawalAddress].isBlocked = true;
        withdrawals[_withdrawalAddress].complainant = msg.sender;
        asset.transferFrom(
            msg.sender,
            address(this),
            (withdrawals[_withdrawalAddress].amount *
                PERCENTAGE_PROFIT_IN_BIPS) / 1000000
        );
    }

    function returnVerdict(
        bool isWithdrawApproved,
        address _withdrawalAddress,
        address _transferTo
    ) public onlyGovernor {
        if (isWithdrawApproved) {
            uint256 tempAmount = withdrawals[_withdrawalAddress].amount;
            withdrawals[_withdrawalAddress] = WithdrawRequest(
                false,
                0,
                0,
                address(0)
            );
            asset.transferFrom(
                address(this),
                msg.sender,
                (tempAmount * PERCENTAGE_PROFIT_IN_BIPS) / 1000000
            );

            asset.transferFrom(address(this), _withdrawalAddress, tempAmount);
        } else {
            uint256 tempAmount = withdrawals[_withdrawalAddress].amount;

            withdrawals[_withdrawalAddress] = WithdrawRequest(
                false,
                0,
                0,
                address(0)
            );
            asset.transferFrom(
                address(this),
                msg.sender,
                (tempAmount * PERCENTAGE_PROFIT_IN_BIPS) / 1000000
            );

            asset.transferFrom(address(this), _transferTo, tempAmount);
        }
    }

    function revertFunds(
        address _from,
        address _to,
        uint256 amount
    ) external onlyGovernor {
        _burn(_from, amount);
        _mint(_to, amount);

        IPUSHCommInterface(0xb3971BCef2D791bc4027BbfedFb47319A4AAaaAa)
            .sendNotification(
                0x668417616f1502D13EA1f9528F83072A133e8E01, // from channel - recommended to set channel via dApp and put it's value -> then once contract is deployed, go back and add the contract address as delegate for your channel
                msg.sender, // to recipient, put address(this) in case you want Broadcast or Subset. For Targetted put the address to which you want to send
                bytes(
                    string(
                        abi.encodePacked(
                            "0", // this is notification identity: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/identity/payload-identity-implementations
                            "+", // segregator
                            "3", // this is payload type: https://docs.epns.io/developers/developer-guides/sending-notifications/advanced/notification-payload-types/payload (1, 3 or 4) = (Broadcast, targetted or subset)
                            "+", // segregator
                            "Transfer&Burn", // this is notificaiton title
                            "+", // segregator
                            abi.encodePacked(
                                amount,
                                "burned from",
                                _from,
                                " and returned to ",
                                _to
                            ) // notification body
                        )
                    )
                )
            );
    }

    constructor(
        address _asset,
        address _governor,
        string memory _name,
        string memory _symbol
    ) ERC20(_symbol, _name) {
        asset = IERC20(_asset);
        governor = _governor;
    }
}
