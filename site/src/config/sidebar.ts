export interface SidebarEntry {
  slug: string;
  label: string;
}

export interface SidebarGroup {
  id: 'getting-started' | 'guides' | 'reference';
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
    ],
  },
  {
    id: 'guides',
    label: 'Guides',
    entries: [
      { slug: 'recipes', label: 'Recipes' },
      { slug: 'framework', label: 'Framework' },
      { slug: 'typescript-sdk', label: 'TypeScript SDK' },
      { slug: 'configuration', label: 'Configuration' },
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
    ],
  },
];
