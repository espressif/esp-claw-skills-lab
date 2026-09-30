import fs from 'node:fs'
import path from 'node:path'
import { readAppPackage } from '../build/app-package'

const root = path.resolve(import.meta.dirname, '..', 'apps')
const entries = fs.existsSync(root)
  ? fs.readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory())
  : []
let failures = 0
for (const entry of entries) {
  try {
    readAppPackage(path.join(root, entry.name))
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    failures++
  }
}
if (failures) process.exitCode = 1
else console.log(`All ${entries.length} App packages passed validation.`)
