import {
  bytesToHex,
  cre,
  encodeCallMsg,
  getNetwork,
  handler,
  hexToBase64,
  hexToBytes,
  prepareReportRequest,
  Runner,
  type EVMLog,
  type Runtime,
} from "@chainlink/cre-sdk";
import { EVM_PB } from "@chainlink/cre-sdk/pb";
import { create } from "@bufbuild/protobuf";
import {
  concatHex,
  decodeEventLog,
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getEventSelector,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";

type ChainConfig = {
  name: string;
  chainSelectorName: string;
  vaultAddress: Address;
  receiverAddress: Address;
  routerAddress: Address;
  linkTokenAddress: Address;
};

type Config = {
  chains: ChainConfig[];
  preflight: {
    checkLink: boolean;
    checkToken: boolean;
  };
  extraArgsGasLimit: number | string | null;
  writeGasLimit?: number | string | null;
};

type ChainContext = {
  config: ChainConfig;
  chainSelector: bigint;
  evmClient: InstanceType<typeof cre.capabilities.EVMClient>;
};

type TokenAmount = {
  token: Address;
  amount: bigint;
};

type EVM2AnyMessage = {
  receiver: Hex;
  data: Hex;
  tokenAmounts: TokenAmount[];
  feeToken: Address;
  extraArgs: Hex;
};

const EVM_EXTRA_ARGS_V1_TAG: Hex = "0x97a657c9";

const VAULT_EVENTS_ABI = [
  {
    type: "event",
    name: "DepositRequested",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "targetChainSelector", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "WithdrawRequested",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "targetChainSelector", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "WithdrawExecutionRequested",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "token", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
      { name: "targetChainSelector", type: "uint64", indexed: false },
    ],
  },
] as const;

const VAULT_WRITE_ABI = [
  {
    type: "function",
    name: "executeCCIPSend",
    inputs: [
      { name: "destinationChainSelector", type: "uint64" },
      {
        name: "message",
        type: "tuple",
        components: [
          { name: "receiver", type: "bytes" },
          { name: "data", type: "bytes" },
          {
            name: "tokenAmounts",
            type: "tuple[]",
            components: [
              { name: "token", type: "address" },
              { name: "amount", type: "uint256" },
            ],
          },
          { name: "feeToken", type: "address" },
          { name: "extraArgs", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "messageId", type: "bytes32" }],
    stateMutability: "nonpayable",
  },
] as const;

const ROUTER_ABI = [
  {
    type: "function",
    name: "getFee",
    inputs: [
      { name: "destinationChainSelector", type: "uint64" },
      {
        name: "message",
        type: "tuple",
        components: [
          { name: "receiver", type: "bytes" },
          { name: "data", type: "bytes" },
          {
            name: "tokenAmounts",
            type: "tuple[]",
            components: [
              { name: "token", type: "address" },
              { name: "amount", type: "uint256" },
            ],
          },
          { name: "feeToken", type: "address" },
          { name: "extraArgs", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "fee", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "balance", type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const EVENT_SELECTORS = [
  getEventSelector("DepositRequested(address,address,uint256,uint64)"),
  getEventSelector("WithdrawRequested(address,address,uint256,uint64)"),
  getEventSelector("WithdrawExecutionRequested(address,address,uint256,uint64)"),
];

const buildTopics = () => [
  { values: EVENT_SELECTORS.map(hexToBase64) },
  { values: [] },
  { values: [] },
  { values: [] },
];

const buildExtraArgs = (extraArgsGasLimit: Config["extraArgsGasLimit"]): Hex => {
  if (extraArgsGasLimit === null || extraArgsGasLimit === undefined) {
    return "0x";
  }
  const gasLimit =
    typeof extraArgsGasLimit === "string"
      ? BigInt(extraArgsGasLimit)
      : BigInt(extraArgsGasLimit);
  const encodedArgs = encodeAbiParameters([{ type: "uint256" }], [gasLimit]);
  return concatHex([EVM_EXTRA_ARGS_V1_TAG, encodedArgs]);
};

const encodeReceiverBytes = (receiver: Address): Hex =>
  encodeAbiParameters([{ type: "address" }], [receiver]);

const encodeOperationData = (operation: string, params: Hex): Hex =>
  encodeAbiParameters(
    [{ type: "string" }, { type: "bytes" }],
    [operation, params],
  );

const buildMessage = (params: {
  receiverAddress: Address;
  data: Hex;
  tokenAmounts: TokenAmount[];
  feeToken: Address;
  extraArgs: Hex;
}): EVM2AnyMessage => ({
  receiver: encodeReceiverBytes(params.receiverAddress),
  data: params.data,
  tokenAmounts: params.tokenAmounts,
  feeToken: params.feeToken,
  extraArgs: params.extraArgs,
});

const readErc20Balance = (
  runtime: Runtime<Config>,
  ctx: ChainContext,
  token: Address,
  owner: Address,
): bigint => {
  const callData = encodeFunctionData({
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [owner],
  });
  const response = ctx.evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: token,
        data: callData,
      }),
    })
    .result();
  return decodeFunctionResult({
    abi: ERC20_ABI,
    functionName: "balanceOf",
    data: bytesToHex(response.data),
  }) as bigint;
};

const estimateFee = (
  runtime: Runtime<Config>,
  ctx: ChainContext,
  destinationChainSelector: bigint,
  message: EVM2AnyMessage,
): bigint => {
  const callData = encodeFunctionData({
    abi: ROUTER_ABI,
    functionName: "getFee",
    args: [destinationChainSelector, message],
  });
  const response = ctx.evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: ctx.config.routerAddress,
        data: callData,
      }),
    })
    .result();
  return decodeFunctionResult({
    abi: ROUTER_ABI,
    functionName: "getFee",
    data: bytesToHex(response.data),
  }) as bigint;
};

const sendMessage = (
  runtime: Runtime<Config>,
  ctx: ChainContext,
  destinationChainSelector: bigint,
  message: EVM2AnyMessage,
  writeGasLimit?: Config["writeGasLimit"],
) => {
  const callData = encodeFunctionData({
    abi: VAULT_WRITE_ABI,
    functionName: "executeCCIPSend",
    args: [destinationChainSelector, message],
  });
  const report = runtime.report(prepareReportRequest(callData)).result();
  const gasLimit =
    writeGasLimit === null || writeGasLimit === undefined
      ? undefined
      : typeof writeGasLimit === "string"
        ? BigInt(writeGasLimit)
        : BigInt(writeGasLimit);
  const gasConfig = gasLimit
    ? create(EVM_PB.GasConfigSchema, { gasLimit })
    : undefined;
  return ctx.evmClient
    .writeReport(runtime, {
      receiver: hexToBytes(ctx.config.vaultAddress),
      report,
      $report: true,
      gasConfig,
    })
    .result();
};

const preflightChecks = (
  runtime: Runtime<Config>,
  ctx: ChainContext,
  destinationChainSelector: bigint,
  message: EVM2AnyMessage,
  preflight: Config["preflight"],
): boolean => {
  let requiredFee = 0n;
  if (preflight.checkLink) {
    requiredFee = estimateFee(runtime, ctx, destinationChainSelector, message);
    const linkBalance = readErc20Balance(
      runtime,
      ctx,
      ctx.config.linkTokenAddress,
      ctx.config.vaultAddress,
    );
    if (linkBalance < requiredFee) {
      runtime.log(
        `[${ctx.config.name}] Insufficient LINK. Have ${linkBalance} need ${requiredFee}`,
      );
      return false;
    }
  }

  if (preflight.checkToken && message.tokenAmounts.length > 0) {
    const { token, amount } = message.tokenAmounts[0];
    const tokenBalance = readErc20Balance(
      runtime,
      ctx,
      token,
      ctx.config.vaultAddress,
    );
    if (tokenBalance < amount) {
      runtime.log(
        `[${ctx.config.name}] Insufficient token balance. Have ${tokenBalance} need ${amount}`,
      );
      return false;
    }
  }

  return true;
};

type HandlerResult = {
  status: "sent" | "skipped" | "error";
  detail: string;
  txStatus?: number;
  txHash?: Hex;
};

const handleVaultLog = (
  runtime: Runtime<Config>,
  log: EVMLog,
  sourceCtx: ChainContext,
  chainBySelector: Map<string, ChainContext>,
  settings: Pick<Config, "preflight" | "extraArgsGasLimit" | "writeGasLimit">,
): HandlerResult => {
  if (log.removed) {
    runtime.log(
      `[${sourceCtx.config.name}] Ignoring removed log ${bytesToHex(
        log.txHash,
      )}`,
    );
    return { status: "skipped", detail: "log_removed" };
  }

  let decoded:
    | {
        eventName: "DepositRequested" | "WithdrawRequested" | "WithdrawExecutionRequested";
        args: Record<string, unknown>;
      }
    | undefined;

  if (log.topics.length === 0) {
    runtime.log(
      `[${sourceCtx.config.name}] Log has no topics; skipping decode.`,
    );
    return { status: "skipped", detail: "no_topics" };
  }

  try {
    const topics = log.topics.map((topic) => bytesToHex(topic)) as [
      Hex,
      ...Hex[],
    ];
    decoded = decodeEventLog({
      abi: VAULT_EVENTS_ABI,
      data: bytesToHex(log.data),
      topics,
    }) as typeof decoded;
  } catch (error) {
    runtime.log(
      `[${sourceCtx.config.name}] Failed to decode log: ${(error as Error).message}`,
    );
    return { status: "error", detail: "decode_failed" };
  }

  if (!decoded) {
    runtime.log(`[${sourceCtx.config.name}] Unsupported event payload`);
    return { status: "skipped", detail: "unsupported_event" };
  }

  const extraArgs = buildExtraArgs(settings.extraArgsGasLimit);

  try {
    if (decoded.eventName === "DepositRequested") {
      const { user, token, amount, targetChainSelector } = decoded.args as {
        user: Address;
        token: Address;
        amount: bigint;
        targetChainSelector: bigint;
      };

      const destination = chainBySelector.get(targetChainSelector.toString());
      if (!destination) {
        runtime.log(
          `[${sourceCtx.config.name}] Unknown destination selector ${targetChainSelector.toString()}`,
        );
        return { status: "skipped", detail: "unknown_destination" };
      }

      const params = encodeAbiParameters([{ type: "address" }], [user]);
      const message = buildMessage({
        receiverAddress: destination.config.receiverAddress,
        data: encodeOperationData("DEPOSIT", params),
        tokenAmounts: [{ token, amount }],
        feeToken: sourceCtx.config.linkTokenAddress,
        extraArgs,
      });

      if (
        !preflightChecks(
          runtime,
          sourceCtx,
          destination.chainSelector,
          message,
          settings.preflight,
        )
      ) {
        return { status: "skipped", detail: "preflight_failed" };
      }

      const result = sendMessage(
        runtime,
        sourceCtx,
        destination.chainSelector,
        message,
        settings.writeGasLimit,
      );
      const txHash = result.txHash ? bytesToHex(result.txHash) : undefined;
      runtime.log(
        `[${sourceCtx.config.name}] DepositRequested sent via CCIP. Tx status ${result.txStatus} ${
          txHash ? `txHash ${txHash}` : ""
        }`.trim(),
      );
      return {
        status: "sent",
        detail: "deposit_requested",
        txStatus: result.txStatus,
        txHash,
      };
    }

    if (decoded.eventName === "WithdrawRequested") {
      const { user, token, amount, targetChainSelector } = decoded.args as {
        user: Address;
        token: Address;
        amount: bigint;
        targetChainSelector: bigint;
      };

      const destination = chainBySelector.get(targetChainSelector.toString());
      if (!destination) {
        runtime.log(
          `[${sourceCtx.config.name}] Unknown destination selector ${targetChainSelector.toString()}`,
        );
        return { status: "skipped", detail: "unknown_destination" };
      }

      const params = encodeAbiParameters(
        [
          { type: "address" },
          { type: "address" },
          { type: "uint256" },
          { type: "uint64" },
        ],
        [user, token, amount, targetChainSelector],
      );

      const message = buildMessage({
        receiverAddress: destination.config.receiverAddress,
        data: encodeOperationData("WITHDRAW", params),
        tokenAmounts: [],
        feeToken: sourceCtx.config.linkTokenAddress,
        extraArgs,
      });

      if (
        !preflightChecks(
          runtime,
          sourceCtx,
          destination.chainSelector,
          message,
          settings.preflight,
        )
      ) {
        return { status: "skipped", detail: "preflight_failed" };
      }

      const result = sendMessage(
        runtime,
        sourceCtx,
        destination.chainSelector,
        message,
        settings.writeGasLimit,
      );
      const txHash = result.txHash ? bytesToHex(result.txHash) : undefined;
      runtime.log(
        `[${sourceCtx.config.name}] WithdrawRequested sent via CCIP. Tx status ${result.txStatus} ${
          txHash ? `txHash ${txHash}` : ""
        }`.trim(),
      );
      return {
        status: "sent",
        detail: "withdraw_requested",
        txStatus: result.txStatus,
        txHash,
      };
    }

    if (decoded.eventName === "WithdrawExecutionRequested") {
      const { user, token, amount, targetChainSelector } = decoded.args as {
        user: Address;
        token: Address;
        amount: bigint;
        targetChainSelector: bigint;
      };

      const destination = chainBySelector.get(targetChainSelector.toString());
      if (!destination) {
        runtime.log(
          `[${sourceCtx.config.name}] Unknown destination selector ${targetChainSelector.toString()}`,
        );
        return { status: "skipped", detail: "unknown_destination" };
      }

      const params = encodeAbiParameters([{ type: "address" }], [user]);
      const message = buildMessage({
        receiverAddress: destination.config.receiverAddress,
        data: encodeOperationData("DEPOSIT", params),
        tokenAmounts: [{ token, amount }],
        feeToken: sourceCtx.config.linkTokenAddress,
        extraArgs,
      });

      if (
        !preflightChecks(
          runtime,
          sourceCtx,
          destination.chainSelector,
          message,
          settings.preflight,
        )
      ) {
        return { status: "skipped", detail: "preflight_failed" };
      }

      const result = sendMessage(
        runtime,
        sourceCtx,
        destination.chainSelector,
        message,
        settings.writeGasLimit,
      );
      const txHash = result.txHash ? bytesToHex(result.txHash) : undefined;
      runtime.log(
        `[${sourceCtx.config.name}] WithdrawExecutionRequested sent via CCIP. Tx status ${result.txStatus} ${
          txHash ? `txHash ${txHash}` : ""
        }`.trim(),
      );
      return {
        status: "sent",
        detail: "withdraw_execution_requested",
        txStatus: result.txStatus,
        txHash,
      };
    }
  } catch (error) {
    runtime.log(
      `[${sourceCtx.config.name}] Handler error: ${(error as Error).message}`,
    );
    return { status: "error", detail: "handler_exception" };
  }

  return { status: "skipped", detail: "no_handler_match" };
};

const createChainContext = (chain: ChainConfig): ChainContext => {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: chain.chainSelectorName,
    isTestnet: true,
  });

  if (!network) {
    throw new Error(
      `Unsupported chain selector name: ${chain.chainSelectorName}`,
    );
  }

  return {
    config: chain,
    chainSelector: network.chainSelector.selector,
    evmClient: new cre.capabilities.EVMClient(network.chainSelector.selector),
  };
};

const initWorkflow = (config: Config) => {
  const chainContexts = config.chains.map(createChainContext);
  const chainBySelector = new Map<string, ChainContext>(
    chainContexts.map((ctx) => [ctx.chainSelector.toString(), ctx]),
  );

  return chainContexts.map((ctx) =>
    handler<EVMLog, EVMLog, Config, HandlerResult>(
      ctx.evmClient.logTrigger({
        addresses: [hexToBase64(ctx.config.vaultAddress)],
        topics: buildTopics(),
        confidence: "CONFIDENCE_LEVEL_SAFE",
      }),
      (runtime: Runtime<Config>, log: EVMLog) =>
        handleVaultLog(runtime, log, ctx, chainBySelector, {
          preflight: config.preflight,
          extraArgsGasLimit: config.extraArgsGasLimit,
          writeGasLimit: config.writeGasLimit,
        }),
    ),
  );
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
