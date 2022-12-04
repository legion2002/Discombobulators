// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
        // Add EPNS notification here
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

    function returnVerdict(bool isWithdrawApproved, address _withdrawalAddress)
        public
        onlyGovernor
    {
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

            asset.transferFrom(address(this), _withdrawalAddress, tempAmount);
        }
    }

    function revertFunds(
        address _from,
        address _to,
        uint256 amount
    ) external onlyGovernor {
        _burn(_from, amount);
        _mint(_to, amount);
        // Add EPNS notification here
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
