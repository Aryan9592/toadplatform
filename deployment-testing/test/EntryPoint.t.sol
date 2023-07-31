// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestHelper.sol";
import "../src/EntryPoint.sol";
import "../src/SimpleAccount.sol";
import "../src/SimpleAccountFactory.sol";
import "../src/test/TestWarmColdAccount.sol";
import "../src/test/TestPaymasterAcceptAll.sol";
import "../src/test/TestRevertAccount.sol";

contract EntryPointTest is TestHelper {
    UserOperation[] internal ops;

    function setUp() public {
        owner = createAddress("owner_entrypoint");
        deployEntryPoint(123441);
        createAccount(123442, 123443);
    }

    // Stake Management testing
    // Should deposit for transfer into EntryPoint
    function testDeposit(address signerAddress) public {
        entryPoint.depositTo{value: 1 ether}(signerAddress);

        assertEq(entryPoint.balanceOf(signerAddress), 1 ether);

        assertEq(entryPoint.getDepositInfo(signerAddress).deposit, 1 ether);
        assertEq(entryPoint.getDepositInfo(signerAddress).staked, false);
        assertEq(entryPoint.getDepositInfo(signerAddress).stake, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).unstakeDelaySec, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).withdrawTime, 0);
    }

    // Without stake
    // Should fail to stake without value
    function testNoStakeSpecified(uint32 unstakeDelaySec) public {
        if (unstakeDelaySec > 0) {
            vm.expectRevert(bytes("no stake specified"));
            entryPoint.addStake(unstakeDelaySec);
        }
    }

    // Should fail to stake without delay
    function testNoDelaySpecified() public {
        vm.expectRevert(bytes("must specify unstake delay"));
        entryPoint.addStake{value: 1 ether}(0);
    }

    // Should fail to unlock
    function testNoStakeUnlock() public {
        vm.expectRevert(bytes("not staked"));
        entryPoint.unlockStake();
    }

    // With stake of 2 eth
    // Should report "staked" state
    function testStakedState(address signerAddress) public {
        // add balance to temp address
        vm.deal(signerAddress, 3 ether);
        // set msg.sender to specific address
        vm.prank(signerAddress);
        entryPoint.addStake{value: 2 ether}(2);

        assertEq(entryPoint.getDepositInfo(signerAddress).deposit, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).staked, true);
        assertEq(entryPoint.getDepositInfo(signerAddress).stake, 2 ether);
        assertEq(entryPoint.getDepositInfo(signerAddress).unstakeDelaySec, 2);
        assertEq(entryPoint.getDepositInfo(signerAddress).withdrawTime, 0);
    }

    // With deposit
    // Should be able to withdraw
    function testWithdrawDeposit() public {
        account.addDeposit{value: 1 ether}();

        assertEq(getAccountBalance(), 0);
        assertEq(account.getDeposit(), 1 ether);

        vm.prank(owner.addr);
        account.withdrawDepositTo(payable(accountAddress), 1 ether);

        assertEq(getAccountBalance(), 1 ether);
        assertEq(account.getDeposit(), 0);
    }

    // 2d nonces
    // Should fail nonce with new key and seq!=0
    function test_FailNonce() public {
        (Account memory beneficiary,, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(false);

        UserOperation memory op = _defaultOp;
        op.sender = _accountAddress;
        op.nonce = keyShifed + 1;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // With key=1, seq=1
    // should get next nonce value by getNonce
    function test_GetNonce() public {
        (, uint256 key, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(true);

        uint256 nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        assertEq(nonce, keyShifed + 1);
    }

    // Should allow to increment nonce of different key
    function test_IncrementNonce() public {
        (Account memory beneficiary, uint256 key,, address _accountAddress) = _2dNonceSetup(true);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // should allow manual nonce increment
    function test_ManualNonceIncrement() public {
        (Account memory beneficiary, uint256 key,, address _accountAddress) = _2dNonceSetup(true);

        uint192 incNonceKey = 5;
        bytes memory increment = abi.encodeWithSignature("incrementNonce(uint192)", incNonceKey);
        bytes memory callData =
            abi.encodeWithSignature("execute(address,uint256,bytes)", entryPointAddress, 0, increment);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.callData = callData;
        op2.nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        entryPoint.handleOps(ops, payable(beneficiary.addr));

        uint256 nonce = entryPoint.getNonce(_accountAddress, incNonceKey);
        assertEq(nonce, (incNonceKey * 2 ** 64) + 1);
    }

    // Should fail with nonsequential seq
    function test_NonsequentialNonce() public {
        (Account memory beneficiary,, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(true);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.nonce = keyShifed + 3;
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // Flickering account validation
    // Should prevent leakage of basefee
    function test_BaseFeeLeakage() public {
        /**
         * Create a malicious account
         * Take snapshot
         * RPC call 'evm_mine'
         * Get latest block
         * RPC call 'evm_revert'
         * Validate block baseFeePerGas and expect failure
         * Generate UserOp
         * Trigger Simulate validation
         * Handle revert
         * RPC call 'evm_mine'
         * Trigger Simulate validation
         * Handle revert
         * Expect failures with error messages
         */
    }

    // Should limit revert reason length before emitting it
    function test_RevertReasonLength() public {
        (uint256 revertLength, uint256 REVERT_REASON_MAX_LENGTH) = (1e5, 2048);
        vm.deal(entryPointAddress, 1 ether);
        TestRevertAccount testAccount = new TestRevertAccount(entryPoint);
        bytes memory revertCallData = abi.encodeWithSignature("revertLong(uint256)", revertLength + 1);
        UserOperation memory badOp = _defaultOp;
        badOp.sender = address(testAccount);
        badOp.callGasLimit = 1e5;
        badOp.maxFeePerGas = 1;
        badOp.nonce = entryPoint.getNonce(address(testAccount), 0);
        badOp.verificationGasLimit = 1e5;
        badOp.callData = revertCallData;
        badOp.maxPriorityFeePerGas = 1e9;

        vm.deal(address(testAccount), 0.01 ether);
        Account memory beneficiary = createAddress("beneficiary");
        try entryPoint.simulateValidation{gas: 3e5}(badOp) {}
        catch (bytes memory errorReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(errorReason, 32))
            }
            assertEq(
                reason,
                bytes4(
                    keccak256(
                        "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                    )
                )
            );
        }
        ops.push(badOp);
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary.addr));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[2].topics[0], keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)"));
        (, bytes memory revertReason) = abi.decode(logs[2].data, (uint256, bytes));
        assertEq(revertReason.length, REVERT_REASON_MAX_LENGTH);
    }

    // Warm/cold storage detection in simulation vs execution
    // Should prevent detection through getAggregator()
    function test_DetectionThroughGetAggregator() public {
        uint256 TOUCH_GET_AGGREGATOR = 1;
        TestWarmColdAccount testAccount = new TestWarmColdAccount(entryPoint);
        UserOperation memory badOp = _defaultOp;
        badOp.nonce = TOUCH_GET_AGGREGATOR;
        badOp.sender = address(testAccount);

        Account memory beneficiary = createAddress("beneficiary");

        try entryPoint.simulateValidation{gas: 1e6}(badOp) {}
        catch (bytes memory revertReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(revertReason, 32))
            }
            if (
                reason
                    == bytes4(
                        keccak256(
                            "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                        )
                    )
            ) {
                ops.push(badOp);
                entryPoint.handleOps{gas: 1e6}(ops, payable(beneficiary.addr));
            } else {
                bytes memory failedOp = abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA23 reverted (or OOG)");
                assertEq(revertReason, failedOp);
            }
        }
    }

    // Should prevent detection through paymaster.code.length
    function test_DetectionThroughPaymasterCodeLength() public {
        uint256 TOUCH_PAYMASTER = 2;
        TestWarmColdAccount testAccount = new TestWarmColdAccount(entryPoint);
        TestPaymasterAcceptAll paymaster = new TestPaymasterAcceptAll(entryPoint);
        paymaster.deposit{value: 1 ether}();

        UserOperation memory badOp = _defaultOp;
        badOp.nonce = TOUCH_PAYMASTER;
        badOp.sender = address(testAccount);
        badOp.paymasterAndData = abi.encodePacked(address(paymaster));
        badOp.verificationGasLimit = 1000;

        Account memory beneficiary = createAddress("beneficiary");

        try entryPoint.simulateValidation{gas: 1e6}(badOp) {}
        catch (bytes memory revertReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(revertReason, 32))
            }
            if (
                reason
                    == bytes4(
                        keccak256(
                            "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                        )
                    )
            ) {
                ops.push(badOp);
                entryPoint.handleOps{gas: 1e6}(ops, payable(beneficiary.addr));
            } else {
                bytes memory failedOp = abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA23 reverted (or OOG)");
                assertEq(revertReason, failedOp);
            }
        }
    }

    function _2dNonceSetup(bool triggerHandelOps) internal returns (Account memory, uint256, uint256, address) {
        Account memory beneficiary = createAddress("beneficiary");
        uint256 key = 1;
        uint256 keyShifed = key * 2 ** 64;

        (, address _accountAddress) = createAccountWithFactory(123422);
        vm.deal(_accountAddress, 1 ether);

        if (!triggerHandelOps) {
            return (beneficiary, key, keyShifed, _accountAddress);
        }
        UserOperation memory op = _defaultOp;
        op.sender = _accountAddress;
        op.nonce = keyShifed;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);

        entryPoint.handleOps(ops, payable(beneficiary.addr));
        return (beneficiary, key, keyShifed, _accountAddress);
    }
}
