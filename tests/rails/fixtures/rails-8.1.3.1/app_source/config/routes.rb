Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      # --- auth -------------------------------------------------------
      post "sessions", to: "sessions#create", as: :sessions
      resources :users, only: [ :create ]

      # --- clubs ------------------------------------------------------
      # `param: :slug` -> the member segment is :slug, not :id.
      resources :clubs, param: :slug, only: [ :index, :show, :update ] do
        resources :memberships, only: [ :create ]
        resources :posts, only: [ :index, :create ]
      end

      # --- posts ------------------------------------------------------
      # Numeric-only id constraint on the member segment.
      resources :posts, only: [ :show ], constraints: { id: /\d+/ } do
        member do
          patch :publish
          post "cover", to: "posts#upload_cover", as: :upload_cover
          get  "cover", to: "posts#show_cover", as: :show_cover
        end
      end

      # --- a bare `scope` with defaults + a format constraint ---------
      scope :internal, defaults: { internal: "true" } do
        get "stats", to: "stats#show", as: :internal_stats,
                     constraints: { format: /json/ }, defaults: { format: "json" }
      end
    end
  end
end
