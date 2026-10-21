TudlaAccounting::Engine.routes.draw do
  root to: "dashboard#index"

  resources :accounts do
    member do
      post :deactivate
      post :reactivate
    end
  end
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
    get :tax
    get :by_dimension
    get :general_ledger
    get :cash_flow
    get :statement
    get :statements
    get :tax_return
  end

  resources :budgets do
    member { post :upload }
  end

  resources :tax_codes, except: :show
  resources :filed_tax_returns, only: %i[index show create] do
    member { post :withdraw }
  end
  resources :tax_return_forms do
    resources :boxes, controller: :tax_return_boxes, except: %i[index show]
  end
  resources :dimensions, except: %i[show destroy] do
    resources :dimension_values, path: "values", only: %i[new create edit update]
  end

  get "banking", to: "banking#index", as: :banking
  scope "banking/:account_id", controller: :banking, as: :banking do
    get "", action: :show, as: :account
    post :import
    post :match_suggestions
    post :record_by_rules
  end
  resources :bank_statement_lines, only: [] do
    member do
      post :match
      post :unmatch
      post :create_entry
      post :record_by_rule
      post :record_payment
    end
  end
  resources :bank_rules, except: :show
  resources :contacts do
    collection { post :import }
  end
  get "sales", to: "documents#index", defaults: { side: "sales" }, as: :sales_documents
  get "purchases", to: "documents#index", defaults: { side: "purchases" }, as: :purchase_documents
  get "sales/payments", to: "payments#index", defaults: { kind: "received" }, as: :received_payments
  get "purchases/payments", to: "payments#index", defaults: { kind: "paid" }, as: :paid_payments
  resources :payments, only: %i[show new create] do
    member { post :void }
  end
  resources :documents, except: :index do
    member do
      post :approve
      post :void
    end
  end

  resources :allocations, only: :create do
    collection { post :oldest_first }
    member { post :reverse }
  end

  resources :recurring_entries do
    collection { post :run }
    member { post :make }
  end

  resources :entries do
    member do
      post :post
      post :reverse
    end
    resources :attachments, only: %i[show create destroy]
  end
end
