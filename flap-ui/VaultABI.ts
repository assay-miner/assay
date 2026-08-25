/**
 * The slice of AssayFlapVault the Flap vault UI calls.
 *
 * Generated from the compiled artifact rather than typed out. Regenerate with
 * `node tools/sync-flap-ui-abi.mjs` after changing the vault.
 */
export const vaultAbi = [
  {
    "type": "function",
    "name": "bounty",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "collect",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "collectable",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "miner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "collected",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "miner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "description",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "endow",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "bnbAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minRewardOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "rewardOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "endowed",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBounties",
    "inputs": [
      {
        "name": "you",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "offset",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "limit",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "page",
        "type": "tuple[]",
        "internalType": "struct AssayFlapVault.BountyCard[]",
        "components": [
          {
            "name": "taskId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "baselineGas",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "bountyBtcb",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "paidBtcb",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "entrants",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "phase",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "endsAt",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "yourScore",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "yourBtcb",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "payouts",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "quote",
    "inputs": [
      {
        "name": "bnbAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "rewardOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "reward",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "solvent",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "sponsor",
    "inputs": [
      {
        "name": "taskId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "stats",
    "inputs": [],
    "outputs": [
      {
        "name": "tasks",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "openTasks",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "unassignedBnb",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "committedBtcb",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "paidBtcb",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minersPaid",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "taxToken",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalPaid",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "unassigned",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  }
] as const;
