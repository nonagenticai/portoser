/**
 * Safely format a number to fixed decimal places
 * @param value - Number to format (may be undefined/null)
 * @param decimals - Number of decimal places (default: 1)
 * @param defaultValue - Value to return if input is invalid (default: '0.0')
 * @returns Formatted string
 */
export function safeToFixed(
  value: number | undefined | null,
  decimals: number = 1,
  defaultValue?: string
): string {
  if (value === undefined || value === null || isNaN(value)) {
    if (defaultValue !== undefined) {
      return defaultValue;
    }
    // Default = "0.<n zeros>" matching the requested decimal count.
    return decimals > 0 ? `0.${'0'.repeat(decimals)}` : '0';
  }
  return value.toFixed(decimals);
}

/**
 * Safely get percentage with fallback
 */
export function safePercent(value: number | undefined | null): string {
  return safeToFixed(value, 1, '0.0') + '%';
}

/**
 * Safely format memory in MB
 */
export function safeMemory(value: number | undefined | null): string {
  return safeToFixed(value, 0, '0') + ' MB';
}
