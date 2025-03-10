/*
 * STableLayout
 * StateController.swift
 * https://github.com/ekazaev/ChatLayout
 *
 * Created by Eugene Kazaev in 2020-2022.
 * Distributed under the MIT license.
 */

import Foundation
import UIKit



/** This protocol exists only to serve an ability to unit test `StateController`. */
protocol STableLayoutRepresentation: AnyObject {
	
	var settings: STableLayoutSettings {get}
	
	var viewSize: CGSize {get}
	var visibleBounds: CGRect {get}
	var layoutFrame: CGRect {get}
	var effectiveTopOffset: CGFloat {get}
	
	var adjustedContentInset: UIEdgeInsets {get}
	
	var keepContentOffsetAtBottomOnBatchUpdates: Bool {get}
	
	func numberOfItems(in section: Int) -> Int
	func configuration(for element: ItemKind, at itemPath: ItemPath) -> Item.Configuration
	
	func shouldPresentHeader(at sectionIndex: Int) -> Bool
	func shouldPresentFooter(at sectionIndex: Int) -> Bool
	
}


final class StateController {
	
	private enum CompensatingAction {
		case insert
		case delete
		case frameUpdate(previousFrame: CGRect, newFrame: CGRect)
	}
	
	/* This thing exists here as `UICollectionView` calls `targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint)` only once at the beginning of the animated updates.
	 * But we must compensate the other changes that happened during the update. */
	var batchUpdateCompensatingOffset: CGFloat = 0
	var proposedCompensatingOffset: CGFloat = 0
	var totalProposedCompensatingOffset: CGFloat = 0
	
	var isAnimatedBoundsChange = false
	var isCollectionViewUpdate = false
	
	private(set) var storage: [ModelState: LayoutModel]
	
	private(set) var reloadedIndexes: Set<IndexPath> = []
	private(set) var insertedIndexes: Set<IndexPath> = []
	private(set) var movedIndexes: Set<IndexPath> = []
	private(set) var deletedIndexes: Set<IndexPath> = []
	
	private(set) var reloadedSectionsIndexes: Set<Int> = []
	private(set) var insertedSectionsIndexes: Set<Int> = []
	private(set) var deletedSectionsIndexes: Set<Int> = []
	private(set) var movedSectionsIndexes: Set<Int> = []
	
	private var cachedAttributesState: (rect: CGRect, attributes: [STableLayoutAttributes])?
	/** If I understand upstream and his blog post correctly, this is used to be able to return the _same_ attribute for a given item in order to avoid some animation glitches. */
	private var cachedAttributeObjects = [ModelState: [ItemKind: [ItemPath: STableLayoutAttributes]]]()
	
	private unowned var layoutRepresentation: STableLayoutRepresentation
	
	init(layoutRepresentation: STableLayoutRepresentation) {
		self.layoutRepresentation = layoutRepresentation
		self.storage = [.beforeUpdate: LayoutModel(sections: [], collectionLayout: self.layoutRepresentation)]
		resetCachedAttributeObjects()
	}
	
	func set(_ sections: [Section], at state: ModelState) {
		var layoutModel = LayoutModel(sections: sections, collectionLayout: layoutRepresentation)
		layoutModel.assembleLayout()
		storage[state] = layoutModel
	}
	
	func contentHeight(at state: ModelState) -> CGFloat {
		guard let locationHeight = storage[state]?.sections.last?.locationHeight else {
			return 0
		}
		return locationHeight + layoutRepresentation.settings.additionalInsets.bottom
	}
	
	func layoutAttributesForElements(in rect: CGRect, state: ModelState, ignoreCache: Bool = false, allowPinning: Bool = true) -> [STableLayoutAttributes] {
		let predicate: (STableLayoutAttributes) -> ComparisonResult = { attributes in
			if attributes.frame.intersects(rect) {
				return .orderedSame
			}
			if attributes.frame.minY > rect.maxY {
				return .orderedDescending
			}
			return .orderedAscending
		}
		
		if !ignoreCache,
			let cachedAttributesState = cachedAttributesState,
			cachedAttributesState.rect.contains(rect)
		{
			/* We use the cache for the static attributes, but we must re-compute the pinned attributes. */
			let (_, pinnedAttributes) = allAttributes(at: state, visibleRect: rect, allowPinning: allowPinning, returnPinnedOnly: true)
			return (
				cachedAttributesState.attributes.binarySearchRange(predicate: predicate) +
				pinnedAttributes.binarySearchRange(predicate: predicate)
			)
		} else {
			let totalRect: CGRect
			switch state {
				case .beforeUpdate: totalRect = rect.inset(by: UIEdgeInsets(top: -rect.height / 2, left: -rect.width / 2, bottom: -rect.height / 2, right: -rect.width / 2))
				case  .afterUpdate: totalRect = rect
			}
			let (staticAttributes, pinnedAttributes) = allAttributes(at: state, visibleRect: totalRect, allowPinning: allowPinning)
			if !ignoreCache {
				cachedAttributesState = (rect: totalRect, attributes: staticAttributes)
			}
			let visibleStaticAttributes = (rect != totalRect ? staticAttributes.binarySearchRange(predicate: predicate) : staticAttributes)
			let visiblePinnedAttributes = (rect != totalRect ? pinnedAttributes.binarySearchRange(predicate: predicate) : pinnedAttributes)
			return (visibleStaticAttributes + visiblePinnedAttributes)
		}
	}
	
	func resetCachedAttributes() {
		cachedAttributesState = nil
	}
	
	func resetCachedAttributeObjects() {
		ModelState.allCases.forEach{ state in
			resetCachedAttributeObjects(at: state)
		}
	}
	
	private func resetCachedAttributeObjects(at state: ModelState) {
		cachedAttributeObjects[state] = [:]
		ItemKind.allCases.forEach{ kind in
			cachedAttributeObjects[state]?[kind] = [:]
		}
	}
	
	func itemAttributes(for itemPath: ItemPath, kind: ItemKind, predefinedFrame: CGRect? = nil, at state: ModelState) -> STableLayoutAttributes? {
		let attributes: STableLayoutAttributes
		let itemIndexPath = itemPath.indexPath
		
		guard let item = item(for: itemPath, kind: kind, at: state) else {
			return nil
		}
		let section = layout(at: state).sections[itemPath.section]
		let frame = predefinedFrame ?? frame(of: item, in: section, at: state, isFinal: true)
		
		switch kind {
			case .header:
				if let cachedAttributes = cachedAttributeObjects[state]?[.header]?[itemPath] {
					attributes = cachedAttributes
				} else {
					attributes = STableLayoutAttributes(forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, with: itemIndexPath)
					cachedAttributeObjects[state]?[.header]?[itemPath] = attributes
				}
				attributes.zIndex = 10
				
			case .footer:
				if let cachedAttributes = cachedAttributeObjects[state]?[.footer]?[itemPath] {
					attributes = cachedAttributes
				} else {
					attributes = STableLayoutAttributes(forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, with: itemIndexPath)
					cachedAttributeObjects[state]?[.footer]?[itemPath] = attributes
				}
				attributes.zIndex = 10
				
			case .cell:
				if let cachedAttributes = cachedAttributeObjects[state]?[.cell]?[itemPath] {
					attributes = cachedAttributes
				} else {
					attributes = STableLayoutAttributes(forCellWith: itemIndexPath)
					cachedAttributeObjects[state]?[.cell]?[itemPath] = attributes
				}
				attributes.zIndex = 0
		}
		
#if DEBUG
		attributes.id = item.id
#endif
		attributes.frame = frame
		attributes.indexPath = itemIndexPath
		attributes.alignment = item.alignment
		attributes.pinned = item.pinning != .none
		attributes.viewSize = layoutRepresentation.viewSize
		attributes.layoutFrame = layoutRepresentation.layoutFrame
//		attributes.visibleBoundsSize = layoutRepresentation.visibleBounds.size
		attributes.adjustedContentInsets = layoutRepresentation.adjustedContentInset
		attributes.additionalInsets = layoutRepresentation.settings.additionalInsets
		return attributes
	}
	
	func itemFrame(for itemPath: ItemPath, kind: ItemKind, at state: ModelState, isFinal: Bool = false, allowPinning: Bool = true) -> CGRect? {
		guard let item = item(for: itemPath, kind: kind, at: state) else {
			return nil
		}
		let section = layout(at: state).sections[itemPath.section]
		return frame(of: item, in: section, at: state, isFinal: isFinal, allowPinning: allowPinning)
	}
	
	func frame(of item: Item, in section: Section, at state: ModelState, isFinal: Bool = false, allowPinning: Bool = true) -> CGRect {
		var itemFrame = item.frame
		let dx: CGFloat
		let visibleBounds = layoutRepresentation.visibleBounds
		let additionalInsets = layoutRepresentation.settings.additionalInsets
		
		switch item.alignment {
			case .leading:
				dx = additionalInsets.left
				
			case .trailing:
				dx = visibleBounds.size.width - itemFrame.width - additionalInsets.right
				
			case .center:
				let availableWidth = visibleBounds.size.width - additionalInsets.right - additionalInsets.left
				dx = additionalInsets.left + availableWidth / 2 - itemFrame.width / 2
				
			case .fullWidth:
				dx = additionalInsets.left
				itemFrame.size.width = layoutRepresentation.layoutFrame.size.width
		}
		
		let pinningOffset: CGFloat
		switch (allowPinning, item.pinning) {
			case (false, _), (_, .none):
				pinningOffset = 0
				
			case (true, .top):
				let doOffset = (isCollectionViewUpdate && state == .beforeUpdate)
				let delta = layoutRepresentation.effectiveTopOffset - section.offsetY - (doOffset ? totalProposedCompensatingOffset : 0)
				if delta > 0 {
					/* The section starts above the current offset, we must move the item to have the pinning. */
					pinningOffset = min(delta, section.height - itemFrame.height)
				} else {
					pinningOffset = 0
				}
				
			case (true, .bottom):
				fatalError("Not implemented")
		}
		
		itemFrame = itemFrame.offsetBy(dx: dx, dy: section.offsetY + pinningOffset)
		if isFinal {
			itemFrame = offsetByCompensation(frame: itemFrame, for: state, backward: true)
		}
		return itemFrame
	}
	
	func itemPath(by itemId: UUID, kind: ItemKind, at state: ModelState) -> ItemPath? {
		return layout(at: state).itemPath(by: itemId, kind: kind)
	}
	
	func sectionIdentifier(for index: Int, at state: ModelState) -> UUID? {
		guard index < layout(at: state).sections.count else {
			/* This occurs when getting layout attributes for initial / final animations. */
			return nil
		}
		return layout(at: state).sections[index].id
	}
	
	func sectionIndex(for sectionIdentifier: UUID, at state: ModelState) -> Int? {
		guard let sectionIndex = layout(at: state).sectionIndex(by: sectionIdentifier) else {
			/* This occurs when getting layout attributes for initial / final animations. */
			return nil
		}
		return sectionIndex
	}
	
	func section(at index: Int, at state: ModelState) -> Section {
		guard index < layout(at: state).sections.count else {
			preconditionFailure("Section index \(index) is bigger than the amount of sections \(layout(at: state).sections.count)")
		}
		return layout(at: state).sections[index]
	}
	
	func itemIdentifier(for itemPath: ItemPath, kind: ItemKind, at state: ModelState) -> UUID? {
		guard itemPath.section < layout(at: state).sections.count else {
			/* This occurs when getting layout attributes for initial / final animations. */
			return nil
		}
		let sectionModel = layout(at: state).sections[itemPath.section]
		switch kind {
			case .cell:
				guard itemPath.item < layout(at: state).sections[itemPath.section].items.count else {
					/* This occurs when getting layout attributes for initial / final animations. */
					return nil
				}
				let rowModel = sectionModel.items[itemPath.item]
				return rowModel.id
				
			case .header, .footer:
				guard let item = item(for: ItemPath(item: 0, section: itemPath.section), kind: kind, at: state) else {
					return nil
				}
				return item.id
		}
	}
	
	func numberOfSections(at state: ModelState) -> Int {
		return layout(at: state).sections.count
	}
	
	func numberOfItems(in sectionIndex: Int, at state: ModelState) -> Int {
		return layout(at: state).sections[sectionIndex].items.count
	}
	
	func item(for itemPath: ItemPath, kind: ItemKind, at state: ModelState) -> Item? {
		switch kind {
			case .header:
				guard itemPath.section < layout(at: state).sections.count,
						itemPath.item == 0
				else {
					/* This occurs when getting layout attributes for initial / final animations. */
					return nil
				}
				guard let header = layout(at: state).sections[itemPath.section].header else {
					return nil
				}
				return header
				
			case .footer:
				guard itemPath.section < layout(at: state).sections.count,
						itemPath.item == 0
				else {
					/* This occurs when getting layout attributes for initial / final animations. */
					return nil
				}
				guard let footer = layout(at: state).sections[itemPath.section].footer else {
					return nil
				}
				return footer
				
			case .cell:
				guard itemPath.section < layout(at: state).sections.count,
						itemPath.item < layout(at: state).sections[itemPath.section].count
				else {
					/* This occurs when getting layout attributes for initial / final animations. */
					return nil
				}
				return layout(at: state).sections[itemPath.section].items[itemPath.item]
		}
	}
	
	func update(preferredSize: CGSize, alignment: STableItemAlignment, for itemPath: ItemPath, kind: ItemKind, at state: ModelState) {
		guard var item = item(for: itemPath, kind: kind, at: state) else {
			assertionFailure("Item at index path (\(itemPath.section) - \(itemPath.item)) does not exist.")
			return
		}
		var layout = self.layout(at: state)
		let previousFrame = item.frame
		cachedAttributesState = nil
		item.alignment = alignment
		item.calculatedSize = preferredSize
		item.calculatedOnce = true
		
		switch kind {
			case .header: layout.setAndAssemble(header: item, sectionIndex: itemPath.section)
			case .footer: layout.setAndAssemble(footer: item, sectionIndex: itemPath.section)
			case .cell:   layout.setAndAssemble(item: item, sectionIndex: itemPath.section, itemIndex: itemPath.item)
		}
		storage[state] = layout
		let frameUpdateAction = CompensatingAction.frameUpdate(previousFrame: previousFrame, newFrame: item.frame)
		compensateOffsetIfNeeded(for: itemPath, kind: kind, action: frameUpdateAction)
	}
	
	func process(changeItems: [ChangeItem]) {
		batchUpdateCompensatingOffset = 0
		proposedCompensatingOffset = 0
		let changeItems = changeItems.sorted()
		
		var afterUpdateModel = layout(at: .beforeUpdate)
		resetCachedAttributeObjects()
		
		changeItems.forEach{ updateItem in
			switch updateItem {
				case let .sectionInsert(sectionIndex: sectionIndex):
					let items = (0..<layoutRepresentation.numberOfItems(in: sectionIndex)).map{ index -> Item in
						let itemIndexPath = IndexPath(item: index, section: sectionIndex)
						return Item(with: layoutRepresentation.configuration(for: .cell, at: itemIndexPath.itemPath))
					}
					let header: Item?
					if layoutRepresentation.shouldPresentHeader(at: sectionIndex) == true {
						let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
						header = Item(with: layoutRepresentation.configuration(for: .header, at: headerIndexPath.itemPath))
					} else {
						header = nil
					}
					let footer: Item?
					if layoutRepresentation.shouldPresentFooter(at: sectionIndex) == true {
						let footerIndexPath = IndexPath(item: 0, section: sectionIndex)
						footer = Item(with: layoutRepresentation.configuration(for: .footer, at: footerIndexPath.itemPath))
					} else {
						footer = nil
					}
					let section = Section(header: header, footer: footer, items: items, collectionLayout: layoutRepresentation)
					afterUpdateModel.insertSection(section, at: sectionIndex)
					insertedSectionsIndexes.insert(sectionIndex)
					
				case let .itemInsert(itemIndexPath: indexPath):
					let item = Item(with: layoutRepresentation.configuration(for: .cell, at: indexPath.itemPath))
					insertedIndexes.insert(indexPath)
					afterUpdateModel.insertItem(item, at: indexPath)
					
				case let .sectionDelete(sectionIndex: sectionIndex):
					let section = layout(at: .beforeUpdate).sections[sectionIndex]
					deletedSectionsIndexes.insert(sectionIndex)
					afterUpdateModel.removeSection(by: section.id)
					
				case let .itemDelete(itemIndexPath: indexPath):
					let itemId = itemIdentifier(for: indexPath.itemPath, kind: .cell, at: .beforeUpdate)!
					afterUpdateModel.removeItem(by: itemId)
					deletedIndexes.insert(indexPath)
					
				case let .sectionReload(sectionIndex: sectionIndex):
					reloadedSectionsIndexes.insert(sectionIndex)
					var section = layout(at: .beforeUpdate).sections[sectionIndex]
					
					var header: Item?
					if layoutRepresentation.shouldPresentHeader(at: sectionIndex) == true {
						let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
						header = section.header ?? Item(with: layoutRepresentation.configuration(for: .header, at: headerIndexPath.itemPath))
						header?.resetSize()
					} else {
						header = nil
					}
					section.set(header: header)
					
					var footer: Item?
					if layoutRepresentation.shouldPresentFooter(at: sectionIndex) == true {
						let footerIndexPath = IndexPath(item: 0, section: sectionIndex)
						footer = section.footer ?? Item(with: layoutRepresentation.configuration(for: .footer, at: footerIndexPath.itemPath))
						footer?.resetSize()
					} else {
						footer = nil
					}
					section.set(footer: footer)
					
					let oldItems = section.items
					let items: [Item] = (0..<layoutRepresentation.numberOfItems(in: sectionIndex)).map{ index in
						var newItem: Item
						if index < oldItems.count {
							newItem = oldItems[index]
						} else {
							let itemIndexPath = IndexPath(item: index, section: sectionIndex)
							newItem = Item(with: layoutRepresentation.configuration(for: .cell, at: itemIndexPath.itemPath))
						}
						newItem.resetSize()
						return newItem
					}
					section.set(items: items)
					afterUpdateModel.removeSection(for: sectionIndex)
					afterUpdateModel.insertSection(section, at: sectionIndex)
					
				case let .itemReload(itemIndexPath: indexPath):
					guard var item = self.item(for: indexPath.itemPath, kind: .cell, at: .beforeUpdate) else {
						assertionFailure("Item at index path (\(indexPath.section) - \(indexPath.item)) does not exist.")
						return
					}
					item.resetSize()
					
					afterUpdateModel.replaceItem(item, at: indexPath)
					reloadedIndexes.insert(indexPath)
					
				case let .sectionMove(initialSectionIndex: initialSectionIndex, finalSectionIndex: finalSectionIndex):
					let section = layout(at: .beforeUpdate).sections[initialSectionIndex]
					movedSectionsIndexes.insert(finalSectionIndex)
					afterUpdateModel.removeSection(by: section.id)
					afterUpdateModel.insertSection(section, at: finalSectionIndex)
					
				case let .itemMove(initialItemIndexPath: initialItemIndexPath, finalItemIndexPath: finalItemIndexPath):
					let itemId = itemIdentifier(for: initialItemIndexPath.itemPath, kind: .cell, at: .beforeUpdate)!
					let item = layout(at: .beforeUpdate).sections[initialItemIndexPath.section].items[initialItemIndexPath.item]
					movedIndexes.insert(initialItemIndexPath)
					afterUpdateModel.removeItem(by: itemId)
					afterUpdateModel.insertItem(item, at: finalItemIndexPath)
			}
		}
		
		afterUpdateModel = LayoutModel(sections: afterUpdateModel.sections.map{ section -> Section in
			var section = section
			section.assembleLayout()
			return section
		}, collectionLayout: layoutRepresentation)
		afterUpdateModel.assembleLayout()
		storage[.afterUpdate] = afterUpdateModel
		
		/* Calculating potential content offset changes after the updates. */
		insertedSectionsIndexes.sorted{ $0 < $1 }.forEach{
			compensateOffsetOfSectionIfNeeded(for: $0, action: .insert)
		}
		reloadedSectionsIndexes.sorted{ $0 < $1 }.forEach{
			let oldSection = self.section(at: $0, at: .beforeUpdate)
			guard let newSectionIndex = self.sectionIndex(for: oldSection.id, at: .afterUpdate) else {
				assertionFailure("Section with identifier \(oldSection.id) does not exist.")
				return
			}
			let newSection = self.section(at: newSectionIndex, at: .afterUpdate)
			compensateOffsetOfSectionIfNeeded(for: $0, action: .frameUpdate(previousFrame: oldSection.frame, newFrame: newSection.frame))
		}
		deletedSectionsIndexes.sorted{ $0 < $1 }.forEach{
			compensateOffsetOfSectionIfNeeded(for: $0, action: .delete)
		}
		
		reloadedIndexes.sorted{ $0 < $1 }.forEach{
			guard let oldItem = self.item(for: $0.itemPath, kind: .cell, at: .beforeUpdate),
					let newItemIndexPath = self.itemPath(by: oldItem.id, kind: .cell, at: .afterUpdate),
					let newItem = self.item(for: newItemIndexPath, kind: .cell, at: .afterUpdate)
			else {
				assertionFailure("Internal inconsistency")
				return
			}
			compensateOffsetIfNeeded(for: $0.itemPath, kind: .cell, action: .frameUpdate(previousFrame: oldItem.frame, newFrame: newItem.frame))
		}
		
		insertedIndexes.sorted{ $0 < $1 }.forEach{
			compensateOffsetIfNeeded(for: $0.itemPath, kind: .cell, action: .insert)
		}
		deletedIndexes.sorted{ $0 < $1 }.forEach{
			compensateOffsetIfNeeded(for: $0.itemPath, kind: .cell, action: .delete)
		}
		
		totalProposedCompensatingOffset = proposedCompensatingOffset
	}
	
	func commitUpdates() {
		insertedIndexes = []
		insertedSectionsIndexes = []
		
		reloadedIndexes = []
		reloadedSectionsIndexes = []
		
		movedIndexes = []
		movedSectionsIndexes = []
		
		deletedIndexes = []
		deletedSectionsIndexes = []
		
		storage[.beforeUpdate] = layout(at: .afterUpdate)
		storage[.afterUpdate] = nil
		
		totalProposedCompensatingOffset = 0
		
		cachedAttributeObjects[.beforeUpdate] = cachedAttributeObjects[.afterUpdate]
		resetCachedAttributeObjects(at: .afterUpdate)
	}
	
	func contentSize(for state: ModelState) -> CGSize {
		let contentHeight = self.contentHeight(at: state)
		guard contentHeight != 0 else {
			return .zero
		}
		/* This is a workaround for `layoutAttributesForElementsInRect:` not getting invoked enough times if
		 *  `collectionViewContentSize.width` is not smaller than the width of the collection view, minus horizontal insets.
		 * This results in visual defects when performing batch updates.
		 * To work around this, we subtract 0.0001 from our content size width calculation;
		 *  this small decrease in `collectionViewContentSize.width` is enough to work around the incorrect internal collection view `CGRect` checks,
		 *  without introducing any visual differences for elements in the collection view.
		 * See https://openradar.appspot.com/radar?id=5025850143539200 for more details. */
		let contentSize = CGSize(width: layoutRepresentation.visibleBounds.size.width - 0.0001, height: contentHeight)
		return contentSize
	}
	
	func offsetByTotalCompensation(attributes: UICollectionViewLayoutAttributes?, for state: ModelState, backward: Bool = false) {
		guard layoutRepresentation.keepContentOffsetAtBottomOnBatchUpdates,
				state == .afterUpdate,
				let attributes = attributes
		else {
			return
		}
		if backward, isLayoutBiggerThanVisibleBounds(at: .afterUpdate) {
			attributes.frame = attributes.frame.offsetBy(dx: 0, dy: totalProposedCompensatingOffset * -1)
		} else if !backward, isLayoutBiggerThanVisibleBounds(at: .afterUpdate) {
			attributes.frame = attributes.frame.offsetBy(dx: 0, dy: totalProposedCompensatingOffset)
		}
	}
	
	func layout(at state: ModelState) -> LayoutModel {
		guard let layout = storage[state] else {
			assertionFailure("Internal inconsistency. Layout at \(state) is missing.")
			return LayoutModel(sections: [], collectionLayout: layoutRepresentation)
		}
		return layout
	}
	
	func isLayoutBiggerThanVisibleBounds(at state: ModelState, withFullCompensation: Bool = false) -> Bool {
		let visibleBoundsHeight = layoutRepresentation.visibleBounds.height + (withFullCompensation ? batchUpdateCompensatingOffset + proposedCompensatingOffset : 0)
		return contentHeight(at: state).rounded() > visibleBoundsHeight.rounded()
	}
	
	private func allAttributes(at state: ModelState, visibleRect: CGRect? = nil, allowPinning: Bool = true, returnPinnedOnly: Bool = false) -> (static: [STableLayoutAttributes], pinned: [STableLayoutAttributes]) {
		let layout = self.layout(at: state)
		
		if let visibleRect = visibleRect {
			enum TraversalState {
				case notFound
				case found
				case done
			}
			
			var staticTraversalState: TraversalState = .notFound
			
			func check(_ rect: CGRect, _ pinned: Bool) -> Bool {
				guard !pinned else {
					return visibleRect.intersects(rect)
				}
				guard !returnPinnedOnly else {
					return false
				}
				
				switch staticTraversalState {
					case .notFound:
						if visibleRect.intersects(rect) {
							staticTraversalState = .found
							return true
						} else {
							return false
						}
						
					case .found:
						if visibleRect.intersects(rect) {
							return true
						} else {
							if rect.minY > visibleRect.maxY + batchUpdateCompensatingOffset + proposedCompensatingOffset {
								staticTraversalState = .done
							}
							return false
						}
						
					case .done:
						return false
				}
			}
			
			var allStaticRects = [(frame: CGRect, indexPath: ItemPath, kind: ItemKind)]()
			var allPinnedRects = [(frame: CGRect, indexPath: ItemPath, kind: ItemKind)]()
			/* I dont think there can be more then a 200 elements on the screen simultaneously. */
			if !returnPinnedOnly {allStaticRects.reserveCapacity(200)}
			allPinnedRects.reserveCapacity(10)
			for sectionIndex in 0..<layout.sections.count {
				let section = layout.sections[sectionIndex]
				guard section.frame.intersects(visibleRect) else {continue}
				
				/* Do we have a header for this section? */
				if let headerItem = section.header {
					let sectionPath = ItemPath(item: 0, section: sectionIndex)
					let headerFrame = frame(of: headerItem, in: section, at: state, isFinal: true, allowPinning: allowPinning)
					if check(headerFrame, headerItem.pinned) {
						if headerItem.pinned {allPinnedRects.append((frame: headerFrame, indexPath: sectionPath, kind: .header))}
						else                 {allStaticRects.append((frame: headerFrame, indexPath: sectionPath, kind: .header))}
					}
				}
				guard staticTraversalState != .done else {
					break
				}
				
				var startingIndex = 0
				/* If header is not visible (or is pinned), we have to compute the first visible static item. */
				if !returnPinnedOnly, staticTraversalState == .notFound, let lastIndex = section.staticItemIndexes.last {
					func predicate(itemIndex: Int) -> ComparisonResult {
						let item = section.items[itemIndex]
						let itemFrame = frame(of: item, in: section, at: state, isFinal: true, allowPinning: allowPinning)
						if itemFrame.intersects(visibleRect) {
							return .orderedSame
						}
						if itemFrame.minY > visibleRect.maxY {
							return .orderedDescending
						}
						return .orderedAscending
					}
					
					/* Find if any of the items of the section is visible. */
					if [ComparisonResult.orderedSame, .orderedDescending].contains(predicate(itemIndex: lastIndex)),
						let firstMatchingIndex = section.staticItemIndexes.binarySearch(predicate: predicate)
					{
						/* Find first item that is visible. */
						startingIndex = firstMatchingIndex
						for itemIndex in section.staticItemIndexes.prefix(while: { $0 < firstMatchingIndex }).reversed() {
							let item = section.items[itemIndex]
							let itemFrame = frame(of: item, in: section, at: state, isFinal: true, allowPinning: allowPinning)
							guard itemFrame.maxY >= visibleRect.minY else {
								break
							}
							startingIndex = itemIndex
						}
					} else {
						/* Otherwise we can safely skip all the items in the section and go to footer. */
						startingIndex = section.items.count
					}
				}
				
				/* Process the static items.
				 * We process the pinned item indexes first because they will not change the traversal state. */
				for itemIndex in section.pinnedItemIndexes + (!returnPinnedOnly ? section.staticItemIndexes.drop(while: { $0 < startingIndex }) : []) {
					let itemPath = ItemPath(item: itemIndex, section: sectionIndex)
					let item = section.items[itemIndex]
					
					let itemFrame = frame(of: item, in: section, at: state, isFinal: true, allowPinning: allowPinning)
					if check(itemFrame, item.pinned) {
						if state == .beforeUpdate || isAnimatedBoundsChange {
							if !item.pinned {allStaticRects.append((frame: itemFrame, indexPath: itemPath, kind: .cell))}
							else            {allPinnedRects.append((frame: itemFrame, indexPath: itemPath, kind: .cell))}
						} else {
							/* TVR note: The thing about these two complicated checks is: they are probably useless and we probably could add the rects unconditionally because AFAIK the collection view does not care if some layout attributes outside of the requested rect are returned. */
							var itemWasVisibleBefore: Bool {
								guard let itemIdentifier = itemIdentifier(for: itemPath, kind: .cell, at: .afterUpdate),
										let initialIndexPath = self.itemPath(by: itemIdentifier, kind: .cell, at: .beforeUpdate),
										let item = self.item(for: initialIndexPath, kind: .cell, at: .beforeUpdate),
										item.calculatedOnce == true,
										frame(of: item, in: self.layout(at: .beforeUpdate).sections[initialIndexPath.section], at: .beforeUpdate, isFinal: false, allowPinning: allowPinning)
											.intersects(layoutRepresentation.visibleBounds.offsetBy(dx: 0, dy: -totalProposedCompensatingOffset))
								else {
									return false
								}
								return true
							}
							var itemWillBeVisible: Bool {
								let offsetVisibleBounds = layoutRepresentation.visibleBounds.offsetBy(dx: 0, dy: proposedCompensatingOffset + batchUpdateCompensatingOffset)
								let itemFrameIntersectsOffsetVisibleBounds = itemFrame.intersects(offsetVisibleBounds)
								
								if insertedIndexes.contains(itemPath.indexPath), itemFrameIntersectsOffsetVisibleBounds {
									return true
								}
								
								if let itemIdentifier = self.itemIdentifier(for: itemPath, kind: .cell, at: .afterUpdate),
									let initialIndexPath = self.itemPath(by: itemIdentifier, kind: .cell, at: .beforeUpdate)?.indexPath,
									movedIndexes.contains(initialIndexPath) || reloadedIndexes.contains(initialIndexPath),
									/* TVR note: Upstream’s implementation used to have the following line here, instead of `itemFrameIntersectsOffsetVisibleBounds`:
									 *   frame(of: item, in: section, at: state, isFinal: true, allowPinning: allowPinning).intersects(offsetVisibleBounds)
									 * Indeed, the frame computation here should be exactly equal to itemFrame, and we can thus use the variable instead of recomputing everything.
									 * I _think_ however the actual frame expected if the one of the initial index path, but I’m not sure… */
									itemFrameIntersectsOffsetVisibleBounds
								{
									return true
								}
								return false
							}
							if itemWillBeVisible || itemWasVisibleBefore {
								if !item.pinned {allStaticRects.append((frame: itemFrame, indexPath: itemPath, kind: .cell))}
								else            {allPinnedRects.append((frame: itemFrame, indexPath: itemPath, kind: .cell))}
							}
						}
					}
					guard staticTraversalState != .done else {
						break
					}
				}
				
				/* Do we have a header for this section? */
				if let footerItem = section.footer {
					let sectionPath = ItemPath(item: 0, section: sectionIndex)
					let footerFrame = frame(of: footerItem, in: section, at: state, isFinal: true, allowPinning: allowPinning)
					if check(footerFrame, footerItem.pinned) {
						if footerItem.pinned {allPinnedRects.append((frame: footerFrame, indexPath: sectionPath, kind: .footer))}
						else                 {allStaticRects.append((frame: footerFrame, indexPath: sectionPath, kind: .footer))}
					}
				}
				
				guard staticTraversalState != .done else {
					break
				}
			}
			
			return (
				allStaticRects.compactMap{ frame, path, kind -> STableLayoutAttributes? in
					return self.itemAttributes(for: path, kind: kind, predefinedFrame: frame, at: state)
				},
				allPinnedRects.compactMap{ frame, path, kind -> STableLayoutAttributes? in
					return self.itemAttributes(for: path, kind: kind, predefinedFrame: frame, at: state)
				}
			)
		} else {
			/* Debug purposes only. */
			var normalAttributes = [STableLayoutAttributes]()
			var pinnedAttributes = [STableLayoutAttributes]()
			layout.sections.enumerated().forEach{ sectionIndex, section in
				let sectionPath = ItemPath(item: 0, section: sectionIndex)
				if let headerAttributes = self.itemAttributes(for: sectionPath, kind: .header, at: state) {
					if headerAttributes.pinned {pinnedAttributes.append(headerAttributes)}
					else                       {normalAttributes.append(headerAttributes)}
				}
				if let footerAttributes = self.itemAttributes(for: sectionPath, kind: .footer, at: state) {
					if footerAttributes.pinned {pinnedAttributes.append(footerAttributes)}
					else                       {normalAttributes.append(footerAttributes)}
				}
				section.items.enumerated().forEach{ itemIndex, _ in
					let itemPath = ItemPath(item: itemIndex, section: sectionIndex)
					if let itemAttributes = self.itemAttributes(for: itemPath, kind: .cell, at: state) {
						if itemAttributes.pinned {pinnedAttributes.append(itemAttributes)}
						else                     {normalAttributes.append(itemAttributes)}
					}
				}
			}
			return (normalAttributes, pinnedAttributes)
		}
	}
	
	private func compensateOffsetIfNeeded(for itemPath: ItemPath, kind: ItemKind, action: CompensatingAction) {
		guard layoutRepresentation.keepContentOffsetAtBottomOnBatchUpdates else {
			return
		}
		let minY = (layoutRepresentation.visibleBounds.lowerPoint.y + batchUpdateCompensatingOffset + proposedCompensatingOffset).rounded()
		switch action {
			case .insert:
				guard isLayoutBiggerThanVisibleBounds(at: .afterUpdate),
						let itemFrame = itemFrame(for: itemPath, kind: kind, at: .afterUpdate)
				else {
					return
				}
				if itemFrame.minY.rounded() - layoutRepresentation.settings.interItemSpacing <= minY {
					proposedCompensatingOffset += itemFrame.height + layoutRepresentation.settings.interItemSpacing
				}
			case let .frameUpdate(previousFrame, newFrame):
				guard isLayoutBiggerThanVisibleBounds(at: .afterUpdate, withFullCompensation: true) else {
					return
				}
				if newFrame.minY.rounded() <= minY {
					batchUpdateCompensatingOffset += newFrame.height - previousFrame.height
				}
			case .delete:
				guard isLayoutBiggerThanVisibleBounds(at: .beforeUpdate),
						let deletedFrame = itemFrame(for: itemPath, kind: kind, at: .beforeUpdate)
				else {
					return
				}
				if deletedFrame.minY.rounded() <= minY {
					/* Changing content offset for deleted items using `invalidateLayout(with:) causes UI glitches.
					 * So we are using targetContentOffset(forProposedContentOffset:) which is going to be called after. */
					proposedCompensatingOffset -= (deletedFrame.height + layoutRepresentation.settings.interItemSpacing)
				}
		}
		
	}
	
	private func compensateOffsetOfSectionIfNeeded(for sectionIndex: Int, action: CompensatingAction) {
		guard layoutRepresentation.keepContentOffsetAtBottomOnBatchUpdates else {
			return
		}
		let minY = (layoutRepresentation.visibleBounds.lowerPoint.y + batchUpdateCompensatingOffset + proposedCompensatingOffset).rounded()
		switch action {
			case .insert:
				guard isLayoutBiggerThanVisibleBounds(at: .afterUpdate),
						sectionIndex < layout(at: .afterUpdate).sections.count else {
					return
				}
				let section = layout(at: .afterUpdate).sections[sectionIndex]
				
				if section.offsetY.rounded() - layoutRepresentation.settings.interSectionSpacing <= minY {
					proposedCompensatingOffset += section.height + layoutRepresentation.settings.interSectionSpacing
				}
				
			case let .frameUpdate(previousFrame, newFrame):
				guard sectionIndex < layout(at: .afterUpdate).sections.count,
						isLayoutBiggerThanVisibleBounds(at: .afterUpdate, withFullCompensation: true) else {
					return
				}
				if newFrame.minY.rounded() <= minY {
					batchUpdateCompensatingOffset += newFrame.height - previousFrame.height
				}
				
			case .delete:
				guard isLayoutBiggerThanVisibleBounds(at: .afterUpdate),
						sectionIndex < layout(at: .afterUpdate).sections.count else {
					return
				}
				let section = layout(at: .beforeUpdate).sections[sectionIndex]
				if section.locationHeight.rounded() <= minY {
					/* Changing content offset for deleted items using `invalidateLayout(with:) causes UI glitches.
					 * So we are using targetContentOffset(forProposedContentOffset:) which is going to be called after. */
					proposedCompensatingOffset -= (section.height + layoutRepresentation.settings.interSectionSpacing)
				}
		}
		
	}
	
	private func offsetByCompensation(frame: CGRect, for state: ModelState, backward: Bool = false) -> CGRect {
		guard layoutRepresentation.keepContentOffsetAtBottomOnBatchUpdates,
				state == .afterUpdate,
				isLayoutBiggerThanVisibleBounds(at: .afterUpdate)
		else {
			return frame
		}
		return frame.offsetBy(dx: 0, dy: compensationOffset(for: state, backward: backward))
	}
	
	private func compensationOffset(for state: ModelState, backward: Bool = false) -> CGFloat {
		guard layoutRepresentation.keepContentOffsetAtBottomOnBatchUpdates,
				state == .afterUpdate,
				isLayoutBiggerThanVisibleBounds(at: .afterUpdate)
		else {
			return 0
		}
		return proposedCompensatingOffset * (backward ? -1 : 1)
	}
	
}

extension RandomAccessCollection where Index == Int {
	
	func binarySearch(predicate: (Element) -> ComparisonResult) -> Index? {
		var lowerBound = startIndex
		var upperBound = endIndex
		
		while lowerBound < upperBound {
			let midIndex = lowerBound + (upperBound - lowerBound) / 2
			if predicate(self[midIndex]) == .orderedSame {
				return midIndex
			} else if predicate(self[midIndex]) == .orderedAscending {
				lowerBound = midIndex + 1
			} else {
				upperBound = midIndex
			}
		}
		return nil
	}
	
	func binarySearchRange(predicate: (Element) -> ComparisonResult) -> [Element] {
		guard let firstMatchingIndex = binarySearch(predicate: predicate) else {
			return []
		}
		
		var startingIndex = firstMatchingIndex
		for index in (0..<firstMatchingIndex).reversed() {
			let attributes = self[index]
			guard predicate(attributes) == .orderedSame else {
				break
			}
			startingIndex = index
		}
		
		var lastIndex = firstMatchingIndex
		for index in (firstMatchingIndex + 1)..<count {
			let attributes = self[index]
			guard predicate(attributes) == .orderedSame else {
				break
			}
			lastIndex = index
		}
		return Array(self[startingIndex...lastIndex])
	}
	
}
