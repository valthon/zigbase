export interface SidebarEntry {
  slug: string;
  label: string;
}

export interface SidebarGroup {
  id: 'getting-started' | 'guides' | 'features' | 'reference';
  label: string;
  entries: SidebarEntry[];
}

export const sidebar: SidebarGroup[] = [
  {
    id: 'getting-started',
    label: 'Getting started',
    entries: [
      { slug: 'overview', label: 'Overview' },
      { slug: 'quick-start', label: 'Quick start' },
      { slug: 'tutorial', label: 'Tutorial' },
      { slug: 'agents', label: 'For coding agents' },
    ],
  },
  {
    id: 'guides',
    label: 'Guides',
    entries: [
      { slug: 'recipes', label: 'Recipes' },
      { slug: 'framework', label: 'Framework' },
      { slug: 'testing', label: 'Testing' },
      { slug: 'typescript-sdk', label: 'TypeScript SDK' },
      { slug: 'dart-sdk', label: 'Dart SDK' },
      { slug: 'python-sdk', label: 'Python SDK' },
      { slug: 'kotlin-sdk', label: 'Kotlin SDK' },
      { slug: 'configuration', label: 'Configuration' },
      { slug: 'docker', label: 'Docker' },
      { slug: 'serve', label: 'Running the server' },
      { slug: 'migration-tools', label: 'Migration tools' },
    ],
  },
  {
    id: 'features',
    label: 'Feature guides',
    entries: [
      { slug: 'postgres', label: 'PostgreSQL backend' },
      { slug: 'tenancy', label: 'Multi-tenancy' },
      { slug: 'abilities', label: 'Relationship abilities' },
      { slug: 'search', label: 'Full-text & vector search' },
      { slug: 'analytics', label: 'Product analytics' },
      { slug: 'email', label: 'Email' },
      { slug: 'jobs-and-webhooks', label: 'Jobs & webhooks' },
      { slug: 'realtime-broadcast', label: 'Realtime broadcast' },
    ],
  },
  {
    id: 'reference',
    label: 'Reference',
    entries: [
      { slug: 'api', label: 'API' },
      { slug: 'fields', label: 'Fields' },
      { slug: 'known-limitations', label: 'Known limitations' },
      { slug: 'changelog', label: 'Changelog' },
      { slug: 'observability', label: 'Observability' },
    ],
  },
];
