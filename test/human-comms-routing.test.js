#!/usr/bin/env node
'use strict';

const assert = require('assert');
const path = require('path');
const fs = require('fs');
const { extractFrontmatter } = require('../lib/frontmatter');
const { matchSkillsTfIdf } = require('../lib/skill-router');

const root = path.join(__dirname, '..', 'skills');
const skills = [];
function visit(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) visit(file);
    else if (entry.name === 'skill.md') skills.push(extractFrontmatter(file));
  }
}
visit(root);
const name = 'human-comms-hygiene';
const skill = skills.find(s => s.name === name);
assert(skill, 'new skill is discoverable from repository frontmatter');
for (const trigger of skill.triggers) {
  const collisions = skills.filter(s => s.name !== name &&
    [...(s.triggers || []), ...(s.aliases || [])].includes(trigger));
  assert.strictEqual(collisions.length, 0, `duplicate trigger: ${trigger}`);
}
let count = 0;
for (const artifact of ['commit message', 'PR description', 'issue', 'team message']) {
  for (const verb of ['write', 'draft', 'compose', 'prepare', 'revise']) {
    const prompt = `${verb} ${artifact === 'issue' ? 'an' : 'a'} ${artifact}`;
    const matches = matchSkillsTfIdf(prompt, skills, 5);
    assert(matches.some(s => s.name === name), `missing top-five match: ${prompt}`);
    count++;
  }
}
for (const prompt of skill.anti_triggers) {
  const matches = matchSkillsTfIdf(prompt, skills, skills.length);
  assert(!matches.some(s => s.name === name), `near-miss matched: ${prompt}`);
  count++;
}
console.log(`${count} communication routing cases passed; no exact trigger collisions`);
