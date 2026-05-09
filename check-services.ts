#!/usr/bin/env tsx

/**
 * Service Health Checker.
 *
 * Reads `registry.yml` (or $REGISTRY_FILE) to discover services, then probes
 * each one's HTTPS/HTTP endpoint and prints a coloured per-category report.
 *
 * Per-service URL overrides are read from environment variables. The env-var
 * name is the service name uppercased with `-` replaced by `_`, suffixed
 * `_URL` (e.g. `KAG_URL`, `FR_BACKEND_URL`).
 *
 * Optional env vars:
 *   REGISTRY_FILE             Path to the registry (default: ./registry.yml)
 *   PORTOSER_INGRESS_HOST     Hostname/IP of your Caddy ingress (display only)
 *   PORTOSER_CURRENT_MACHINE  Friendly name of the machine running this script
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

interface RegistryService {
  hostname?: string;
  port?: number | string;
  healthcheck_url?: string;
  category?: string;
  current_host?: string;
}

interface Service {
  name: string;
  httpsUrl: string;
  category: string;
  expectedMachine: string;
}

interface HealthResult {
  service: string;
  category: string;
  httpsAccessible: boolean;
  httpsStatus?: number;
  httpsError?: string;
  responseTime?: number;
  diagnosis: string;
}

const colors = {
  reset: '\x1b[0m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
  gray: '\x1b[90m',
  bold: '\x1b[1m',
};

const currentMachine = process.env.PORTOSER_CURRENT_MACHINE ?? 'local';
const ingressHost = process.env.PORTOSER_INGRESS_HOST ?? 'localhost';
const registryPath = resolve(process.env.REGISTRY_FILE ?? 'registry.yml');

if (!existsSync(registryPath)) {
  console.error(`${colors.red}Registry not found:${colors.reset} ${registryPath}`);
  console.error(`Set REGISTRY_FILE to override.`);
  process.exit(2);
}

// Convert YAML → JSON via yq, which the rest of the codebase already requires.
function loadRegistryServices(path: string): Record<string, RegistryService> {
  try {
    const json = execFileSync('yq', ['eval', '-o', 'json', '.services', path], {
      encoding: 'utf-8',
    });
    return JSON.parse(json) ?? {};
  } catch (err) {
    console.error(`${colors.red}Failed to parse registry via yq:${colors.reset}`, err);
    process.exit(2);
  }
}

function envOverride(serviceName: string): string | undefined {
  const key = `${serviceName.toUpperCase().replace(/-/g, '_')}_URL`;
  return process.env[key];
}

function buildUrl(name: string, svc: RegistryService): string | undefined {
  const override = envOverride(name);
  if (override) return override;
  if (svc.healthcheck_url) return svc.healthcheck_url;
  if (svc.hostname) {
    if (svc.port) return `http://${svc.hostname}:${svc.port}/health`;
    return `http://${svc.hostname}/health`;
  }
  return undefined;
}

const registryServices = loadRegistryServices(registryPath);
const services: Service[] = Object.entries(registryServices)
  .map(([name, svc]) => {
    const url = buildUrl(name, svc);
    if (!url) return null;
    return {
      name,
      httpsUrl: url,
      category: svc.category ?? 'Services',
      expectedMachine: svc.current_host ?? 'unknown',
    } satisfies Service;
  })
  .filter((s): s is Service => s !== null);

if (services.length === 0) {
  console.error(
    `${colors.yellow}No probable URLs found in ${registryPath}. ` +
      `Add hostname+port or healthcheck_url to entries under \`services:\`.${colors.reset}`,
  );
  process.exit(2);
}

async function checkUrl(
  url: string,
  timeoutMs = 5000,
): Promise<{ accessible: boolean; status?: number; error?: string; responseTime: number }> {
  // Try a small set of common health endpoints when the URL has no path of
  // its own.
  const u = new URL(url);
  const endpoints = u.pathname && u.pathname !== '/'
    ? [u.pathname]
    : ['/', '/health', '/healthz', '/api/health', '/docs'];

  for (const endpoint of endpoints) {
    const startTime = Date.now();
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

      const response = await fetch(`${u.origin}${endpoint}`, {
        method: 'GET',
        signal: controller.signal,
      });

      clearTimeout(timeoutId);
      const responseTime = Date.now() - startTime;

      if (response.status < 500) {
        return { accessible: true, status: response.status, responseTime };
      }
    } catch {
      // try next endpoint
    }
  }

  return { accessible: false, error: 'No endpoints responded', responseTime: 0 };
}

async function diagnoseService(service: Service): Promise<HealthResult> {
  const result = await checkUrl(service.httpsUrl);

  let diagnosis: string;
  if (result.accessible) {
    const tag = result.status && result.status < 400 ? 'OK' : 'RESPONDS';
    diagnosis = `${service.httpsUrl} is ${tag} (${result.status})`;
  } else {
    diagnosis = `${service.httpsUrl} NOT REACHABLE - check service on ${service.expectedMachine}, ingress config, and DNS`;
  }

  return {
    service: service.name,
    category: service.category,
    httpsAccessible: result.accessible,
    httpsStatus: result.status,
    httpsError: result.error,
    responseTime: result.responseTime,
    diagnosis,
  };
}

function printResults(results: HealthResult[]): void {
  console.log(`\n${colors.bold}${colors.cyan}=== Service Health Report ===${colors.reset}`);
  console.log(
    `${colors.gray}Running on: ${currentMachine} | Ingress: ${ingressHost} | Registry: ${registryPath}${colors.reset}\n`,
  );

  const categories = [...new Set(results.map((r) => r.category))];

  for (const category of categories) {
    console.log(`${colors.bold}${colors.blue}${category}${colors.reset}`);
    console.log(`${colors.gray}${'-'.repeat(80)}${colors.reset}`);

    const categoryResults = results.filter((r) => r.category === category);

    for (const result of categoryResults) {
      const symbol = result.httpsAccessible
        ? `${colors.green}OK${colors.reset}`
        : `${colors.red}FAIL${colors.reset}`;

      console.log(`\n${symbol} ${colors.bold}${result.service}${colors.reset}`);

      if (result.httpsAccessible) {
        const statusColor =
          result.httpsStatus && result.httpsStatus < 400 ? colors.green : colors.yellow;
        console.log(`  Status: ${statusColor}${result.httpsStatus}${colors.reset} (${result.responseTime}ms)`);
      } else {
        console.log(`  Status: ${colors.red}UNREACHABLE${colors.reset} - ${result.httpsError}`);
      }

      console.log(`  ${colors.gray}${result.diagnosis}${colors.reset}`);
    }

    console.log('');
  }

  const working = results.filter((r) => r.httpsAccessible && r.httpsStatus && r.httpsStatus < 400).length;
  const responding = results.filter((r) => r.httpsAccessible).length;
  const failed = results.filter((r) => !r.httpsAccessible).length;

  console.log(`${colors.bold}${colors.cyan}=== Summary ===${colors.reset}`);
  console.log(`${colors.gray}${'-'.repeat(80)}${colors.reset}`);
  console.log(`Total Services: ${results.length}`);
  console.log(`${colors.green}Fully Working (2xx/3xx): ${working}${colors.reset}`);
  console.log(`${colors.yellow}Responding (4xx): ${responding - working}${colors.reset}`);
  console.log(`${colors.red}Not Reachable: ${failed}${colors.reset}\n`);
}

async function main(): Promise<void> {
  console.log(`${colors.bold}${colors.cyan}Service Health Checker${colors.reset}\n`);
  console.log(`${colors.gray}Checking ${services.length} services from ${registryPath}...${colors.reset}\n`);

  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

  const results: HealthResult[] = [];
  const batchSize = 5;
  for (let i = 0; i < services.length; i += batchSize) {
    const batch = services.slice(i, i + batchSize);
    console.log(
      `${colors.gray}Batch ${Math.floor(i / batchSize) + 1}: ${batch.map((s) => s.name).join(', ')}${colors.reset}`,
    );
    const batchResults = await Promise.all(batch.map(diagnoseService));
    results.push(...batchResults);
  }

  printResults(results);
}

// silence unused-var lints
void readFileSync;

main().catch((error) => {
  console.error(`${colors.red}Fatal error:${colors.reset}`, error);
  process.exit(1);
});
