import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const docs = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/docs' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    order: z.number(),
    group: z.enum(['getting-started', 'guides', 'reference']),
  }),
});

const examples = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/examples' }),
  schema: z.object({
    title: z.string(),
    summary: z.string(),
    rung: z.string(),
    order: z.number(),
    repoPath: z.string(),
  }),
});

export const collections = { docs, examples };
