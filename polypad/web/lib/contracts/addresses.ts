export function getFactoryAddress(): `0x${string}` | undefined {
  const addr = process.env.NEXT_PUBLIC_FACTORY_ADDRESS;
  if (!addr || addr === '' || addr === '0x0000000000000000000000000000000000000000') return undefined;
  return addr as `0x${string}`;
}

export function getCommitVaultAddress(): `0x${string}` | undefined {
  const addr = process.env.NEXT_PUBLIC_COMMIT_VAULT_ADDRESS;
  if (!addr || addr === '' || addr === '0x0000000000000000000000000000000000000000') return undefined;
  return addr as `0x${string}`;
}

export function getExplorerUrl(): string {
  return process.env.NEXT_PUBLIC_EXPLORER_URL ?? 'https://robinhoodchain.blockscout.com';
}

export function getExplorerTxUrl(hash: string): string {
  return `${getExplorerUrl()}/tx/${hash}`;
}

export function getExplorerAddressUrl(address: string): string {
  return `${getExplorerUrl()}/address/${address}`;
}
