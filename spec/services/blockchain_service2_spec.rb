# encoding: UTF-8
# frozen_string_literal: true

class FakeBlockchain < Peatio::Blockchain::Abstract
  def initialize; end

  def supports_cash_addr_format?
    false
  end

  def case_sensitive?
    true
  end
end

describe BlockchainService2 do

  let!(:blockchain) { Blockchain.create!(key: 'fake', name: 'fake', client: 'fake', status: 'active', height: 1) }
  let(:block_number) { 1 }
  let(:fake_adapter) { FakeBlockchain.new }
  let(:service) { BlockchainService2.new(blockchain) }

  let!(:fake_currency1) { Currency.create!(id: 'fake1', name: 'fake1', blockchain: blockchain, symbol: 'F') }
  let!(:fake_currency2) { Currency.create!(id: 'fake2', name: 'fake2', blockchain: blockchain, symbol: 'G') }

  let!(:member) { create(:member) }

  let(:transaction) {  Peatio::Transaction.new(hash: 'fake_txid', from_address: 'fake_address', to_address: 'fake_address', amount: 5, block_number: 3, currency_id: 'fake1', txout: 4) }

  let(:expected_transactions) do
    [
      { hash: 'fake_hash1', from_address: 'fake_address2', to_address: 'fake_address', amount: 1, block_number: 2, currency_id: 'fake1', txout: 1 },
      { hash: 'fake_hash2', from_address: 'fake_address', to_address: 'fake_address1', amount: 2, block_number: 2, currency_id: 'fake1', txout: 2 },
      { hash: 'fake_hash3', from_address: 'fake_address1', to_address: 'fake_address2', amount: 3, block_number: 2, currency_id: 'fake2', txout: 3 }
    ].map { |t| Peatio::Transaction.new(t) }
  end

  before do
    Peatio::BlockchainAPI.expects(:adapter_for).with('fake').returns(fake_adapter)
    fake_adapter.stubs(:latest_block_number).returns(4)
    # TODO: Remove me.
    Blockchain.any_instance.stubs(:blockchain_api).returns(fake_adapter)
  end

  # Deposit context: (mock fetch_block)
  #   * Single deposit in block which should be saved.
  #   * Multiple deposits in single block (one saved one updated).
  #   * Multiple deposits for 2 currencies in single block.
  #   * Multiple deposits in single transaction (different txout).
  describe 'Filter Deposits' do

    context 'single fake deposit was created during block processing' do

      before do
        PaymentAddress.create!(currency: fake_currency1,
                               account: member.accounts.find_by(currency: fake_currency1),
                               address: 'fake_address')
        fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
        service.process_block(block_number)
      end

      subject { Deposits::Coin.where(currency: fake_currency1) }

      it { expect(subject.count).to eq 1 }

      context 'creates deposit with correct attributes' do
        before do
          fake_adapter.stubs(:fetch_block!).returns([transaction])
          service.process_block(block_number)
        end

        it { expect(subject.where(txid: transaction.hash,
                        amount: transaction.amount,
                        address: transaction.to_address,
                        block_number: transaction.block_number,
                        txout: transaction.txout).count).to eq 1 }
      end

      context 'process data one more time' do
        before do
          fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
        end

        it { expect { service.process_block(block_number) }.not_to change { subject } }
      end
    end

    context 'two fake deposits for one currency was created during block processing' do
      before do
        PaymentAddress.create!(currency: fake_currency1,
          account: member.accounts.find_by(currency: fake_currency1),
          address: 'fake_address')
        PaymentAddress.create!(currency: fake_currency1,
          account: member.accounts.find_by(currency: fake_currency1),
          address: 'fake_address1')
        fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
        service.process_block(block_number)
      end

      subject { Deposits::Coin.where(currency: fake_currency1) }

      it { expect(subject.count).to eq 2 }

      context 'one deposit was updated' do
        let!(:deposit) do
          Deposit.create!(currency: fake_currency1,
                          member: member,
                          amount: 5,
                          address: 'fake_address',
                          txid: 'fake_txid',
                          block_number: 0,
                          txout: 4,
                          type: Deposits::Coin)
        end
        before do
          fake_adapter.stubs(:fetch_block!).returns([transaction])
          service.process_block(block_number)
        end
        it { expect(Deposits::Coin.find_by(txid: transaction.hash).block_number).to eq(transaction.block_number) }
      end
    end

    context 'two fake deposits for two currency was created during block processing' do
      before do
        PaymentAddress.create!(currency: fake_currency1,
          account: member.accounts.find_by(currency: fake_currency1),
          address: 'fake_address')
        PaymentAddress.create!(currency: fake_currency2,
          account: member.accounts.find_by(currency: fake_currency2),
          address: 'fake_address2')
        fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
        service.process_block(block_number)
      end

      subject { Deposits::Coin.where(currency: [fake_currency1, fake_currency2]) }

      it { expect(subject.count).to eq 2 }

      it 'create for two currency' do
        expect(Deposits::Coin.where(currency: fake_currency1).count).to eq 1
        expect(Deposits::Coin.where(currency: fake_currency2).count).to eq 1
      end
    end
  end

  # Withdraw context: (mock fetch_block)
  #   * Single withdrawal.
  #   * Multiple withdrawals for single currency.
  #   * Multiple withdrawals for 2 currencies.
  describe 'Filter Withdrawals' do

    context 'single fake withdrawal was updated during block processing' do

      let!(:fake_account) { member.get_account(:fake1).tap { |ac| ac.update!(balance: 50) } }
      let!(:withdrawal) do
        Withdraw.create!(member: member,
                         account: fake_account,
                         currency: fake_currency1,
                         amount: 1,
                         txid: 'fake_hash1',
                         rid: 'fake_address',
                         sum: 1,
                         type: Withdraws::Coin,
                         aasm_state: :confirming)
      end

      before do
        fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
        service.process_block(block_number)
      end

      subject { Withdraws::Coin.where(account: fake_account) }

      it { expect(subject.first.block_number).to eq(expected_transactions.first.block_number) }
    end
  end

  context 'two fake withdrawals was updated during block processing' do

    let!(:fake_account1) { member.get_account(:fake1).tap { |ac| ac.update!(balance: 50) } }
    let!(:withdrawals) do
      2.times do |i|
        Withdraw.create!(member: member,
                         account: fake_account1,
                         currency: fake_currency1,
                         amount: 1,
                         txid: "fake_hash#{i+1}",
                         rid: 'fake_address',
                         sum: 1,
                         type: Withdraws::Coin,
                         aasm_state: :confirming)
      end
    end

    before do
      fake_adapter.stubs(:fetch_block!).returns(expected_transactions)
      service.process_block(block_number)
    end

    it do
      expect(Withdraw.find_by(txid: expected_transactions.first.hash).block_number).to eq(expected_transactions.first.block_number)
      expect(Withdraw.find_by(txid: expected_transactions.second.hash).block_number).to eq(expected_transactions.second.block_number)
    end
  end
end
