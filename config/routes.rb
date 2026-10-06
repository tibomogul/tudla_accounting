TudlaAccounting::Engine.routes.draw do
  root to: "dashboard#index"

  resources :accounts
  resources :periods, only: %i[index show new create destroy] do
    member do
      post :close
      post :reopen
    end
  end
  get "activity", to: "activity#index", as: :activity
  get "setup", to: "setup#index", as: :setup
  scope "setup", controller: :setup, as: :setup do
    get :opening_balances
    patch :opening_balances, action: :save_opening_balances
    post :chart_of_accounts
    post :open_items
    post :revaluation
    get :balances
    post :balances, action: :rebuild_balances
  end

  get "reports", to: "reports#index", as: :reports
  scope "reports", controller: :reports, as: :reports do
    get :balance_sheet
    get :profit_and_loss
    get :trial_balance
    get :receivables
    get :payables
  end

  resources :allocations, only: :create do
    collection { post :oldest_first }
    member { post :reverse }
  end

  resources :entries do
    member do
      post :post
      post :reverse
    end
  end
end
